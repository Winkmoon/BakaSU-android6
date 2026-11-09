use std::{
    fs::{File, OpenOptions, Permissions, remove_file, set_permissions},
    io::Write,
    os::fd::{AsRawFd, OwnedFd},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command},
    sync::atomic::{AtomicU32, Ordering},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail, ensure};
use libc::_exit;
use log::{error, info, warn};
use prop_rs_android::{resetprop::ResetProp, sys_prop};
use rustix::{
    event::{PollFd, PollFlags, poll},
    fs::{MemfdFlags, Timespec, memfd_create},
    io::{Errno, FdFlags, fcntl_getfd, fcntl_setfd, read},
    pipe::{PipeFlags, pipe_with},
    process::chdir,
};

use crate::{assets, defs};

use crate::android::{
    init_event::{on_boot_completed, on_post_fs_data, on_services, run_stage},
    ksucalls,
    module::ScriptWait,
    utils::{self, switch_mnt_ns},
};

const WAITSYS_FD_ENV: &str = "KSU_WAITSYS_FD";
const WAITSYS_TEMP_DIRS: &[&str] = &["/data/local/tmp", "/data/adb"];

struct Waitsys {
    child: Child,
    read_fd: OwnedFd,
    /// Set when the executable was materialized as a real file because the
    /// kernel does not provide memfd_create (Android 6 / older kernels).
    temp_path: Option<PathBuf>,
}

/// Create an executable copy of waitsys for kernels without memfd_create.
fn write_waitsys_temp(contents: &[u8]) -> Result<PathBuf> {
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    let mut last_error: Option<anyhow::Error> = None;

    for directory in WAITSYS_TEMP_DIRS {
        let path = Path::new(directory).join(format!(
            "ksud-waitsys-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => file,
            Err(error) => {
                last_error = Some(error.into());
                continue;
            }
        };

        if let Err(error) = file.write_all(contents).and_then(|_| file.flush()) {
            let _ = remove_file(&path);
            last_error = Some(error.into());
            continue;
        }
        drop(file);

        if let Err(error) = set_permissions(&path, Permissions::from_mode(0o700)) {
            let _ = remove_file(&path);
            last_error = Some(error.into());
            continue;
        }

        return Ok(path);
    }

    Err(last_error
        .unwrap_or_else(|| anyhow::anyhow!("no writable directory for waitsys"))
        .context("failed to materialize waitsys"))
}

impl Waitsys {
    fn spawn() -> Result<Self> {
        let waitsys = assets::get_asset("waitsys").context("waitsys is not embedded")?;

        // memfd_create is only available through bionic from API 30 and the
        // kernel syscall is missing on some Android 6 kernels. Fall back to a
        // private executable file when it is unavailable.
        let (program, executable, temp_path) =
            match memfd_create("waitsys", MemfdFlags::CLOEXEC) {
                Ok(executable_fd) => {
                    let mut executable = File::from(executable_fd);
                    executable
                        .write_all(&waitsys)
                        .context("failed to write waitsys to memfd")?;
                    let program = format!("/proc/self/fd/{}", executable.as_raw_fd());
                    (program, Some(executable), None)
                }
                Err(error) => {
                    warn!("memfd_create unavailable ({error}); using a temporary waitsys file");
                    let path = write_waitsys_temp(&waitsys)?;
                    (
                        path.to_string_lossy().into_owned(),
                        None,
                        Some(path),
                    )
                }
            };

        let (read_fd, write_fd) =
            pipe_with(PipeFlags::CLOEXEC).context("failed to create waitsys pipe")?;
        fcntl_setfd(
            &write_fd,
            fcntl_getfd(&write_fd).context("get write_fd flags")? & !FdFlags::CLOEXEC,
        )
        .context("set write_fd flags")?;

        let mut cmd = Command::new(&program);
        cmd.env(WAITSYS_FD_ENV, format!("{}", write_fd.as_raw_fd()));
        let child = match cmd.spawn() {
            Ok(child) => child,
            Err(error) => {
                drop(write_fd);
                drop(executable);
                if let Some(path) = &temp_path {
                    let _ = remove_file(path);
                }
                return Err(error).context("failed to start waitsys");
            }
        };

        drop(write_fd);
        drop(executable);
        Ok(Self {
            child,
            read_fd,
            temp_path,
        })
    }

    fn wait_for_signal(&self, expected: u8, timeout: Duration) -> Result<()> {
        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                bail!("timed out waiting for signal {expected}");
            }

            let remaining = Timespec::try_from(remaining)?;
            let mut poll_fd = [PollFd::new(&self.read_fd, PollFlags::IN)];
            let ready = match poll(&mut poll_fd, Some(&remaining)) {
                Err(Errno::INTR) => continue,
                result => result,
            }?;
            if ready == 0 {
                bail!("timed out waiting for signal {expected}");
            }

            let mut signal = [0_u8; 1];
            let bytes_read = match read(&self.read_fd, &mut signal) {
                Err(Errno::INTR) => continue,
                result => result,
            }?;
            ensure!(
                bytes_read == 1,
                "waitsys pipe closed before signal {expected}"
            );
            let signal = signal[0];
            ensure!(
                signal == expected,
                "unexpected waitsys signal {signal}, expected {expected}"
            );
            return Ok(());
        }
    }

    fn terminate(&mut self) -> Result<()> {
        self.child.kill().ok();
        let result = self.child.wait().context("wait for waitsys");
        if let Some(path) = self.temp_path.take() {
            let _ = remove_file(path);
        }
        result?;
        Ok(())
    }
}

impl Drop for Waitsys {
    fn drop(&mut self) {
        if let Err(error) = self.terminate() {
            warn!("failed to clean up waitsys: {error:#}");
        }
    }
}

fn terminate_waitsys(waitsys: &mut Option<Waitsys>) {
    if let Some(mut waitsys) = waitsys.take()
        && let Err(error) = waitsys.terminate()
    {
        warn!("failed to clean up waitsys: {error:#}");
    }
}

const fn resetprop() -> ResetProp {
    ResetProp {
        skip_svc: true,
        persistent: false,
        persist_only: false,
        verbose: false,
        show_context: false,
        rebuild: false,
    }
}

fn reset_boot_completed() -> Result<()> {
    sys_prop::init().context("Failed to initialize system property API")?;
    let rp = resetprop();
    // Set prop value to 0 in advance to ensure resetprop -w works
    info!("reset boot complete prop to 0");
    rp.set("sys.boot_completed", "0")
        .context("Failed to set sys.boot_completed to 0")?;
    Ok(())
}

fn wait_for_boot_completed() -> Result<()> {
    sys_prop::init().context("Failed to initialize system property API")?;
    let rp = resetprop();
    info!("waiting for boot complete");
    rp.wait("sys.boot_completed", Some("0"), None)
        .context("wait for sys.boot_completed failed")?;
    Ok(())
}

pub fn soft_reboot() -> Result<()> {
    // check it avoid user click "soft_reboot" in manager when version mismatch
    if let Err(e) = ksucalls::ensure_uapi_version_matched() {
        error!("{e:#}, skip soft_reboot");
        return Ok(());
    }

    utils::daemonize_with(true, || -> Result<()> {
        switch_mnt_ns(1)?;
        chdir("/")?;
        Ok(())
    })?;

    info!("emulating soft_reboot!");
    if let Err(e) = reset_boot_completed() {
        warn!("reset boot completed failed: {e}");
    }
    run_stage(
        "emulated-soft-reboot",
        ScriptWait::Until(Instant::now() + defs::EMULATED_SOFT_REBOOT_TIMEOUT),
    );

    let mut waitsys = match Waitsys::spawn() {
        Ok(waitsys) => Some(waitsys),
        Err(error) => {
            warn!("failed to start waitsys: {error:#}");
            None
        }
    };
    let wait_after_stop = waitsys.as_ref().is_some_and(|waitsys| {
        if let Err(error) = waitsys.wait_for_signal(1, defs::WAITSYS_READY_TIMEOUT) {
            warn!("waitsys failed to collect services: {error:#}");
            false
        } else {
            true
        }
    });
    if !wait_after_stop {
        terminate_waitsys(&mut waitsys);
    }

    info!("stop");
    let status = Command::new("stop").status().context("stop failed")?;
    if !status.success() {
        warn!("stop exited with status: {status}");
    }

    if let Some(waitsys) = waitsys.as_ref()
        && let Err(error) = waitsys.wait_for_signal(2, defs::WAITSYS_STOP_TIMEOUT)
    {
        warn!("waitsys failed while waiting for services to stop: {error:#}");
    }
    terminate_waitsys(&mut waitsys);

    info!("post-fs-data");
    on_post_fs_data()?;
    info!("start");
    let status = Command::new("start").status().context("start failed")?;
    if !status.success() {
        warn!("start exited with status: {status}");
    }
    info!("services");
    on_services();
    if let Err(e) = wait_for_boot_completed() {
        warn!("wait for boot completed failed: {e}");
    }
    on_boot_completed();

    unsafe {
        _exit(0);
    }
}
