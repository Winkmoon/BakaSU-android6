package org.bakasu.bakasu.data.startup

import android.annotation.SuppressLint
import android.app.Application
import android.system.Os
import coil.Coil
import coil.ImageLoader
import com.topjohnwu.superuser.internal.MainShell
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.bakasu.bakasu.data.flash.FlashRepository
import org.bakasu.bakasu.data.shell.KsuCliRepository

class ApplicationInitializationRepository(
    private val application: Application,
    private val imageLoader: ImageLoader,
    private val applicationScope: CoroutineScope,
    private val flashRepository: FlashRepository,
    private val ksuCliRepository: KsuCliRepository,
) {
    @SuppressLint("RestrictedApi")
    suspend fun initialize() {
        MainShell.setBuilder(ksuCliRepository.generateMainShellBuilder())
        Coil.setImageLoader(imageLoader)
        // Context#getDataDir is API 24; filesDir.parentFile is the same
        // directory and has existed since the first Android release.
        val dataDir = application.filesDir.parentFile ?: application.filesDir
        File(dataDir, "webroot").mkdirs()
        Os.setenv("TMPDIR", application.cacheDir.absolutePath, true)
        applicationScope.launch {
            runCatching { flashRepository.getInstallEnvironment() }
        }
    }
}
