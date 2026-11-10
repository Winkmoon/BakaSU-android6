#ifndef __KSU_H_SELINUX
#define __KSU_H_SELINUX

#include "linux/types.h"
#include "linux/version.h"
#include "linux/cred.h"

#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)) || defined(KSU_COMPAT_HAS_SELINUX_STATE)
#define KSU_COMPAT_USE_SELINUX_STATE
#endif

// Primary domain is the full BakaSU domain.  The legacy domain is an
// Android-6-compatible fallback and is selected at runtime when the primary
// domain cannot be resolved by the loaded SELinux policy.
#define KERNEL_SU_DOMAIN "ksu"
#define KERNEL_SU_DOMAIN_LEGACY "su"
#define KERNEL_SU_FILE "ksu_file"

#define KERNEL_SU_CONTEXT "u:r:" KERNEL_SU_DOMAIN ":s0"
#define KERNEL_SU_CONTEXT_LEGACY "u:r:" KERNEL_SU_DOMAIN_LEGACY ":s0"
#define KSU_FILE_CONTEXT "u:object_r:" KERNEL_SU_FILE ":s0"
#define ZYGOTE_CONTEXT "u:r:zygote:s0"
#define ZYGOTE_NEXT_DOMAIN "u:r:zygote_next:s0"
#define INIT_CONTEXT "u:r:init:s0"
#define ADBD_CONTEXT "u:r:adbd:s0"

void setup_selinux(const char *, struct cred *);

// Runtime selection: prefer KERNEL_SU_CONTEXT, fall back to
// KERNEL_SU_CONTEXT_LEGACY when the policy does not define the ksu domain.
void ksu_selinux_domain_init(void);
const char *ksu_root_domain(void);
const char *ksu_root_context(void);
bool ksu_selinux_domain_is_legacy(void);

/*
 * True when the kernel has the 4.x sepolicy implementation that can create
 * the advanced ksu domain.  The domain itself is still chosen at runtime;
 * this only prevents an early init.rc probe from downgrading a modern kernel
 * before apply_kernelsu_rules() has had a chance to create the domain.
 */
static inline bool ksu_selinux_advanced_supported(void)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 2, 0)
    return true;
#else
    return false;
#endif
}

void setenforce(bool);

bool getenforce(void);

void cache_sid(void);

bool is_task_ksu_domain(const struct cred *cred);

bool is_ksu_domain(void);

bool is_zygote(const struct cred *cred);

#ifdef CONFIG_KSU_SUSFS
bool is_zygote_next(const struct cred *cred);
#else
static inline bool is_zygote_next(const struct cred *cred)
{
    // no need when susfs disabled
    return false;
}
#endif

bool is_init(const struct cred *cred);

/*
 * True for pid 1 even before SELinux policy/SID cache is ready.  Other
 * tasks fall back to the SELinux init domain check.
 */
bool ksu_is_init_task(void);

bool is_adbd(const struct cred *cred);

void apply_kernelsu_rules(void);

int handle_sepolicy(void __user *user_data, u64 data_len);

void setup_ksu_cred_selinux(void);

bool ksu_is_sid_equal(const struct cred *cred, u32 sid2);
void ksu_set_zygote_sid(void);

#ifdef CONFIG_KSU_SUSFS
u32 susfs_get_sid_from_name(const char *secctx_name);
u32 susfs_get_current_sid(void);
bool susfs_is_current_zygote_domain(void);
void susfs_set_ksu_sid(void);
bool susfs_is_current_ksu_domain(void);
void susfs_set_init_sid(void);
bool susfs_is_current_init_domain(void);
void susfs_set_priv_app_sid(void);
#endif // #ifdef CONFIG_KSU_SUSFS

void escape_to_root_for_adb_root();

struct inode;
struct inode_security_struct;
struct inode_security_struct *ksu_selinux_inode(const struct inode *inode);

#if defined(MODULE) && defined(CONFIG_DEBUG_INFO_BTF)
int __init ksu_selinux_inode_init(void);
#else
static inline int ksu_selinux_inode_init(void)
{
    return 0;
}
#endif

extern u32 ksu_file_sid;

void __init ksu_selinux_init();

#endif
