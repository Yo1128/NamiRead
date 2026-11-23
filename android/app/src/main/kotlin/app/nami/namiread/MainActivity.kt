package app.nami.namiread

import android.app.Activity
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private val cancelled = AtomicBoolean(false)
    private val requestBooks = 4102
    private val requestBackup = 4103

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "app.nami/books").setMethodCallHandler { call, reply ->
            when (call.method) {
                "root" -> reply.success(File(filesDir, "NamiRead").absolutePath)
                "hubGateway" -> {
                    val cm = getSystemService(ConnectivityManager::class.java)
                    val network = cm.activeNetwork
                    val caps = cm.getNetworkCapabilities(network)
                    val local = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true ||
                        caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
                    val route = if (local) cm.getLinkProperties(network)?.routes?.firstOrNull {
                        it.isDefaultRoute && it.gateway is Inet4Address
                    } else null
                    reply.success(route?.gateway?.hostAddress)
                }
                "hubCache" -> reply.success(File(noBackupFilesDir, "hub-books").absolutePath)
                "hubSpace" -> reply.success(StatFs(noBackupFilesDir.path).availableBytes)
                "hubConnections", "saveHubConnections" -> worker.execute {
                    try {
                        val vault = HubVault(this)
                        val value = if (call.method == "hubConnections") vault.read() else {
                            vault.write(call.argument<String>("json")!!)
                            null
                        }
                        runOnUiThread { reply.success(value) }
                    } catch (_: Exception) {
                        runOnUiThread { reply.error("vault", "无法读取或保存受保护的主机连接", null) }
                    }
                }
                "sourceDecode", "readSourceFile" -> worker.execute {
                    try {
                        val text = if (call.method == "sourceDecode") {
                            val name = call.argument<String>("charset")!!
                            val charset = if (name in setOf("gbk", "gb2312")) "GB18030" else name
                            String(call.argument<ByteArray>("bytes")!!, Charset.forName(charset))
                        } else {
                            val uri = Uri.parse(call.argument<String>("uri"))
                            require(uri.scheme == "content") { "请选择系统文件" }
                            val input = contentResolver.openInputStream(uri) ?: error("文件无法打开")
                            input.use { stream ->
                                val output = java.io.ByteArrayOutputStream()
                                val buffer = ByteArray(8192)
                                while (true) {
                                    val count = stream.read(buffer)
                                    if (count < 0) break
                                    require(output.size() + count <= 1024 * 1024) { "书源配置超过 1 MiB" }
                                    output.write(buffer, 0, count)
                                }
                                output.toString("UTF-8")
                            }
                        }
                        runOnUiThread { reply.success(text) }
                    } catch (e: Exception) {
                        runOnUiThread { reply.error("source", e.localizedMessage, null) }
                    }
                }
                "backupDocument" -> {
                    if (pending != null) { reply.error("busy", "系统文件选择器已打开", null); return@setMethodCallHandler }
                    val name = call.argument<String>("name")
                    val intent = Intent(if (name == null) Intent.ACTION_OPEN_DOCUMENT else Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = if (name == null) "*/*" else call.argument<String>("mime") ?: "application/octet-stream"
                        if (name != null) putExtra(Intent.EXTRA_TITLE, name)
                    }
                    pending = reply
                    try { startActivityForResult(intent, requestBackup) }
                    catch (e: Exception) { pending = null; reply.error("picker", "系统文件选择器暂时不可用", null) }
                }
                "transferBackup", "writeDocument" -> {
                    val uri = Uri.parse(call.argument<String>("uri"))
                    val file = File(call.argument<String>("file")!!)
                    val exporting = call.method == "writeDocument" || call.argument<Boolean>("export") == true
                    worker.execute {
                        try {
                            if (exporting) {
                                val stream = contentResolver.openOutputStream(uri, "wt")
                                    ?: throw IllegalStateException("无法写入所选位置")
                                stream.use { out -> file.inputStream().use { it.copyTo(out) }; out.flush() }
                            } else {
                                val available = (StatFs(filesDir.path).availableBytes - (8L shl 20)).coerceAtLeast(0)
                                val stream = contentResolver.openInputStream(uri)
                                    ?: throw IllegalStateException("无法读取所选备份")
                                stream.use { input ->
                                    file.outputStream().use { out ->
                                        val buffer = ByteArray(65536)
                                        var total = 0L
                                        while (true) {
                                            val n = input.read(buffer)
                                            if (n < 0) break
                                            total += n
                                            if (total > available) throw IllegalStateException("设备可用空间不足")
                                            out.write(buffer, 0, n)
                                        }
                                    }
                                }
                            }
                            runOnUiThread { reply.success(null) }
                        } catch (e: Exception) {
                            runOnUiThread { reply.error("document", "文件读写失败，请检查位置和剩余空间：${e.localizedMessage}", null) }
                        }
                    }
                }
                "pick" -> {
                    if (pending != null) { reply.error("busy", "选书器已打开", null); return@setMethodCallHandler }
                    pending = reply
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }
                    try { startActivityForResult(intent, requestBooks) }
                    catch (e: Exception) { pending=null; reply.error("picker", e.localizedMessage, null) }
                }
                "beginImport" -> { cancelled.set(false); reply.success(null) }
                "cancel" -> { cancelled.set(true); reply.success(null) }
                "copy" -> {
                    val uri = Uri.parse(call.argument<String>("uri"))
                    val dest = File(call.argument<String>("dir")!!, "original")
                    worker.execute {
                        try {
                            val stat = StatFs(filesDir.path)
                            val limit = minOf(96L shl 20, (stat.availableBytes - (8L shl 20)).coerceAtLeast(0))
                            val hash = MessageDigest.getInstance("SHA-256")
                            var size = 0L
                            contentResolver.openInputStream(uri)?.use { input ->
                                dest.outputStream().use { output ->
                                    val buf = ByteArray(65536)
                                    while (true) {
                                        if (cancelled.get()) throw IllegalStateException("导入已取消")
                                        val n = input.read(buf)
                                        if (n < 0) break
                                        size += n
                                        if (size > limit) throw IllegalStateException(if (limit < (96L shl 20)) "设备可用空间不足" else "单本文件超过 96 MiB")
                                        output.write(buf, 0, n); hash.update(buf, 0, n)
                                    }
                                    output.fd.sync()
                                }
                            } ?: throw IllegalStateException("无法打开所选文件")
                            val id = hash.digest().joinToString("") { "%02x".format(it) }
                            runOnUiThread { reply.success(id) }
                        } catch (e: Exception) {
                            dest.delete()
                            runOnUiThread { reply.error("copy", e.localizedMessage ?: "复制中断，请重试", null) }
                        }
                    }
                }
                "decode" -> {
                    val dir = File(call.argument<String>("dir")!!)
                    val charset = call.argument<String>("encoding")!!
                    val localImport = call.argument<Boolean>("hub") != true
                    worker.execute {
                        try {
                            val decoder = Charset.forName(charset).newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                            val preview = StringBuilder()

                            java.io.InputStreamReader(File(dir, "original").inputStream(),decoder).use { source ->
                                File(dir,"decoded.txt").bufferedWriter(Charsets.UTF_8).use { sink ->
                                    val buf = CharArray(8192)
                                    while(true) {
                                        if(localImport && cancelled.get()) throw IllegalStateException("导入已取消")
                                        val n=source.read(buf)
                                        if(n<0) break
                                        if((0 until n).any { buf[it]=='\u0000' || buf[it]=='\uFFFD' }) throw IllegalArgumentException("文字编码不匹配")
                                        sink.write(buf,0,n)
                                        if(preview.length<360) preview.append(buf,0,minOf(360-preview.length,n))
                                    }
                                }
                            }
                            runOnUiThread { reply.success(preview.toString().trimStart('\uFEFF')) }
                        } catch(e: Exception) { runOnUiThread { reply.error("encoding","无法按此编码读取，请切换编码或重新选书",null) } }
                    }
                }
                else -> reply.notImplemented()
            }
        }
    }

    @Deprecated("Activity result API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode != requestBooks && requestCode != requestBackup) return
        val reply=pending ?: return
        pending=null
        if (requestCode == requestBackup) {
            reply.success(if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null)
            return
        }
        if(resultCode!=Activity.RESULT_OK || data==null) { reply.success(emptyList<Any>()); return }
        val uris = linkedSetOf<Uri>()
        data.clipData?.let { clip -> for(i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add) }
        data.data?.let(uris::add)
        try {
            val items=uris.map { uri ->
                val name=contentResolver.query(uri,arrayOf(OpenableColumns.DISPLAY_NAME),null,null,null)?.use { c ->
                    if(c.moveToFirst()) c.getString(0) else null
                } ?: uri.lastPathSegment ?: "本地书籍"
                mapOf("uri" to uri.toString(), "name" to name)
            }
            reply.success(items)
        } catch(e: Exception) { reply.error("picker","无法读取所选文件信息，请重试",null) }
    }

    override fun onDestroy() {
        cancelled.set(true)
        worker.shutdown()
        super.onDestroy()
    }
}
