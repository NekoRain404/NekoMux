import 'dart:collection';

/// Selection state for the SFTP file list: the ticked paths plus whether
/// selection mode is active at all.
/// SFTP 文件列表的多选状态：已勾选的路径，以及是否处于多选模式。
///
/// The paths here are absolute and outlive a rebuild, so nothing in this class
/// can tell whether an entry is still on screen. That is why [clear] is called
/// the moment the listing is about to change directory: a batch action must only
/// ever be able to reach paths the user can still see.
/// 这里保存的是绝对路径，且会跨重建存活，因此本类无法知道某个条目是否还在屏幕上。
/// 这就是列表即将切换目录时必须调用 [clear] 的原因：批量操作绝不应触及用户已经
/// 看不到的路径。
class FileSelection {
  final Set<String> _paths = {};
  bool _isActive = false;

  /// Whether the selection bar is showing.
  /// 是否显示多选操作栏。
  bool get isActive => _isActive;

  /// How many entries are selected.
  /// 已选条目数量。
  int get count => _paths.length;

  /// The selected paths, in the order they were selected.
  /// 已选路径，按选中顺序排列。
  Set<String> get paths => UnmodifiableSetView(_paths);

  /// Whether [path] is selected.
  /// [path] 是否已选中。
  bool contains(String path) => _paths.contains(path);

  /// Enters selection mode with [path] selected.
  /// 进入多选模式并选中 [path]。
  void begin(String path) {
    _isActive = true;
    _paths.add(path);
  }

  /// Adds or removes [path].
  /// 加入或移除 [path]。
  ///
  /// Deselecting the last entry leaves selection mode, so "selection mode with
  /// nothing selected" — a bar offering to act on nothing — cannot exist.
  /// 取消选中最后一个条目即退出多选模式，因此不会出现「处于多选模式但什么都没选」
  /// 这种空操作栏的状态。
  void toggle(String path) {
    if (!_paths.remove(path)) _paths.add(path);
    if (_paths.isEmpty) _isActive = false;
  }

  /// Drops every selection and leaves selection mode.
  /// 清空所有选择并退出多选模式。
  void clear() {
    _paths.clear();
    _isActive = false;
  }
}
