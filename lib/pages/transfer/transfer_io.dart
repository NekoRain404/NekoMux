// The device half of a transfer: choosing a file to send, and choosing where a
// finished download lands.
// 传输的设备侧：挑选要送出的文件，以及为已完成的下载选择落地位置。
//
// Nothing here talks to the queue or to a server — it is `dart:io` and the
// system pickers, which is why it can be read (and its decisions argued about)
// without a connection in the picture.
// 这里不接触队列，也不接触服务器——只有 `dart:io` 与系统选择器，因此可以在完全没有
// 连接的语境下阅读它（并讨论其中的取舍）。
//
// Why a download is staged instead of being written straight to its destination
// / 下载为何先落到暂存区，而不是直接写进目的地:
// `FilePicker.saveFile` on Android does **not** return a path this app can write
// to. It asks the user where to put a file and then writes the bytes it was
// given, through the Storage Access Framework, into the `content://` document
// the user chose; what comes back is a `Uri` built from that document's path
// (`/document/primary:Download/x.txt` under the primary volume), which no
// `dart:io` call can open. Its `bytes` parameter is `required`, so the plugin
// cannot be used as a "where would you like this to go" chooser that yields a
// path either. The alternative — `getDirectoryPath` — does return a real path,
// but a path under shared storage, and an app that declares only `INTERNET`
// (see `AndroidManifest.xml`) cannot write there on Android 10+: scoped storage
// refuses it with EACCES, which would make every download fail on the platform
// this app is for.
// Android 上的 `FilePicker.saveFile` **不**返回本应用可写的路径。它先问用户放在哪里，
// 然后自己把收到的字节通过存储访问框架写进用户选中的 `content://` 文档；返回的是由该
// 文档路径拼出的 `Uri`（主存储卷下形如 `/document/primary:Download/x.txt`），没有任何
// `dart:io` 调用能打开它。它的 `bytes` 参数是**必填**的，因此这个插件也无法当作「你想
// 放到哪里」并返回路径的选择器使用。另一条路 `getDirectoryPath` 确实返回真实路径，但
// 那是共享存储下的路径，而只声明了 `INTERNET` 的应用（见 `AndroidManifest.xml`）在
// Android 10+ 上写不进去：分区存储会以 EACCES 拒绝，这会让下载在这个应用真正面向的
// 平台上全军覆没。
//
// So the bytes are streamed by the queue into a file this app owns, and the
// user's chosen destination is honoured by the one mechanism Android offers for
// it: `saveFile`, given the finished file's bytes, when the row offers "Save".
// 因此字节由队列流式写入本应用自有的文件，而用户选定的目的地则由 Android 为此提供的
// 唯一机制来兑现：在行上提供「保存」时，把已完成的文件字节交给 `saveFile`。

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../core/i18n/strings.dart';
import '../../models/transfer_task.dart';

/// The largest file this app will hand to the system save dialog in one piece.
/// 本应用一次性交给系统保存对话框的最大文件。
///
/// `saveFile` takes the whole payload as one `Uint8List` and copies it again on
/// the platform side before writing, so the peak cost of a save is roughly twice
/// the file's size. Above this ceiling the save is refused before a byte is read
/// rather than attempted and lost to the out-of-memory killer halfway through —
/// the transfer itself, which streams, has no such limit.
/// `saveFile` 把整个载荷作为一个 `Uint8List` 接收，并在平台侧再复制一份后才写入，
/// 因此一次保存的峰值开销约为文件大小的两倍。超过此上限时，在读取任何字节之前就拒绝，
/// 而不是尝试到一半被内存杀手干掉——传输本身是流式的，没有这个限制。
const int transferSaveMaxBytes = 64 * 1024 * 1024;

/// One local file the user chose to upload.
/// 用户选择上传的一个本地文件。
class UploadPick {
  /// Local path to read from, or null when there is nothing to send.
  /// 要读取的本地路径；无内容可送时为 null。
  final String? path;

  /// The file's name, as the picker reported it.
  /// 文件名，取自选择器的报告。
  final String name;

  /// Size in bytes, or null when the picker did not report one.
  /// 字节数；选择器未报告时为 null。
  final int? size;

  /// Whether the user dismissed the picker without choosing anything.
  /// 用户是否未做选择就关闭了选择器。
  final bool cancelled;

  const UploadPick({
    this.path,
    this.name = '',
    this.size,
    this.cancelled = false,
  });

  /// Whether this pick can be queued as an upload.
  /// 本次选择是否可以作为上传入队。
  bool get canUpload => !cancelled && path != null && path!.isNotEmpty;
}

/// Asks the user for a file to upload.
/// 向用户询问要上传的文件。
///
/// The size comes from `lengthSync`, which answers from what the picker already
/// reported without touching the disk; a zero or missing size becomes null so
/// the queue measures the file itself instead of showing a 0-byte total — a
/// genuinely empty file is measured to 0 by the runner anyway, and a progress
/// bar for it is meaningless either way.
/// 大小取自 `lengthSync`，它直接回答选择器已报告的值而不触碰磁盘；为 0 或缺失时转为
/// null，让队列自己去量，而不是显示一个 0 字节的总数——空文件本来就会被 runner 量成
/// 0，而且对它来说进度条无论如何都没有意义。
Future<UploadPick> pickUploadFile() async {
  final files = await FilePicker.pickFiles();
  if (files.isEmpty) return const UploadPick(cancelled: true);

  final file = files.first;
  final size = file.lengthSync();
  return UploadPick(
    path: file.path,
    name: file.name,
    size: (size != null && size > 0) ? size : null,
  );
}

/// The directory downloads are staged in until they are saved somewhere.
/// 下载在保存到别处之前所暂存的目录。
///
/// [Directory.systemTemp] is the app's own cache directory on Android: the
/// engine reads the platform's cache path into its own temp-directory setting
/// and hands it to the Dart VM, whose `Directory.systemTemp` is the one location
/// a `dart:io` write is always allowed to use — which is precisely why the
/// staging step exists at all.
/// 在 Android 上 [Directory.systemTemp] 就是应用自己的缓存目录：引擎把平台的缓存路径读入
/// 自身的临时目录设置并交给 Dart VM，而 VM 的 `Directory.systemTemp` 正是 `dart:io`
/// 写入永远被允许的唯一位置——暂存这一步之所以存在，原因正在于此。
///
/// If that is ever not writable, the caller's `createSync` below throws and the
/// user is told so before anything is queued — the failure is loud at the tap,
/// never a task that quietly cannot write.
/// 若该位置某天不可写，调用方的 `createSync` 会抛出，用户会在任何任务入队之前被告知——
/// 失败在点击处就会出声，绝不会变成一个默默写不进去的任务。
Directory transferStagingDirectory() =>
    Directory('${Directory.systemTemp.path}/nekomux_transfers');

/// A fresh staging path for a download called [remoteName].
/// 为名为 [remoteName] 的下载生成一个新的暂存路径。
///
/// Unique per task rather than named after the remote file: two downloads of the
/// same name — from two directories, or the same file twice — must not write
/// over each other's staged bytes while both are in flight. The remote name is
/// kept in the staging name purely to make the directory readable to a human
/// debugging it.
/// 按任务唯一，而不是按远程文件命名：同名文件的两个下载——来自两个目录，或同一个文件
/// 下了两次——不能在都在途中时互相覆盖暂存的字节。暂存名里保留远程文件名，只是为了让人
/// 调试时看得懂。
String stagedDownloadPath(String remoteName) =>
    '${transferStagingDirectory().path}/'
    '${DateTime.now().microsecondsSinceEpoch}_$remoteName';

/// How a "save this finished download" attempt ended.
/// 一次「保存这个已完成的下载」尝试的结局。
enum TransferSaveOutcome {
  /// The user chose a location and the file was written there.
  /// 用户选定了位置，文件已写入。
  saved,

  /// The user dismissed the save dialog.
  /// 用户关闭了保存对话框。
  cancelled,

  /// The staged file is gone — the queue never wrote it, or it was cleared.
  /// 暂存文件已不存在——队列从未写入它，或它已被清理。
  missing,

  /// Larger than [transferSaveMaxBytes].
  /// 大于 [transferSaveMaxBytes]。
  tooLarge,

  /// The save dialog or the write behind it failed.
  /// 保存对话框或其后端的写入失败。
  failed,
}

/// Writes the staged file of [task] wherever the user asks for it.
/// 把 [task] 的暂存文件写到用户指定的位置。
///
/// The staged copy is deliberately left in place afterwards: it lives in the
/// app's cache, the system may clear it whenever it likes, and keeping it costs
/// nothing while letting the user save a second copy somewhere else without
/// downloading it again.
/// 暂存副本在此之后有意保留：它位于应用缓存中，系统随时可以清理它，留着它不花什么
/// 代价，却能让用户不必重新下载就能再存一份到别处。
Future<TransferSaveOutcome> saveTransferToDevice(TransferTask task) async {
  final path = task.localPath;
  if (path == null) return TransferSaveOutcome.missing;

  final file = File(path);
  try {
    if (!await file.exists()) return TransferSaveOutcome.missing;
    final length = await file.length();
    if (length > transferSaveMaxBytes) return TransferSaveOutcome.tooLarge;

    final Uint8List bytes = await file.readAsBytes();
    final saved = await FilePicker.saveFile(
      fileName: task.name,
      bytes: bytes,
      dialogTitle: t('transfer_direction_download'),
    );
    // A null answer is the documented "the user cancelled", and it is the only
    // one: the platform returns a location or nothing at all, so there is no
    // third state to guess at.
    // null 是文档所述的「用户取消」，也是唯一的一种：平台要么返回位置，要么什么都不
    // 返回，没有第三种状态需要猜。
    return saved == null
        ? TransferSaveOutcome.cancelled
        : TransferSaveOutcome.saved;
  } catch (_) {
    // A picker that threw, a file that vanished between the two calls, a write
    // the provider refused. All of them are the same thing to the user: this
    // copy did not happen.
    // 选择器抛出、文件在两次调用之间消失、提供方拒绝了写入。对用户而言这些是同一件事：
    // 这份副本没有生成。
    return TransferSaveOutcome.failed;
  }
}
