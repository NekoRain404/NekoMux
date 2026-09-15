import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/i18n/strings.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';

/// Wireless ADB management page with connection controls and quick command cards.
/// 无线 ADB 管理页面，包含连接控制和快捷命令卡片。
class WirelessAdbPage extends ConsumerStatefulWidget {
  const WirelessAdbPage({super.key});

  @override
  ConsumerState<WirelessAdbPage> createState() => _WirelessAdbPageState();
}

/// Private state managing ADB connection status toggle, device list, and command dialogs.
/// 私有状态，管理 ADB 连接状态切换、设备列表和命令弹窗。
class _WirelessAdbPageState extends ConsumerState<WirelessAdbPage> {
  /// Whether wireless ADB debugging is currently enabled.
  /// 无线 ADB 调试是否已启用。
  bool _wirelessEnabled = false;

  /// Whether a connection attempt is in progress.
  /// 是否正在尝试连接。
  bool _isConnecting = false;

  /// The current ADB connection status text.
  /// 当前 ADB 连接状态文本。
  String _adbStatusKey = 'adb_disconnected';

  /// Text controllers for the target device IP and port fields.
  /// 目标设备 IP 和端口输入框的文本控制器。
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '5555');

  final List<_MockAdbDevice> _connectedDevices = [];

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  /// Toggles the wireless debugging switch on/off.
  /// 切换无线调试开关。
  void _toggleWirelessDebugging(bool enabled) {
    HapticFeedback.lightImpact();
    setState(() {
      _wirelessEnabled = enabled;
      if (!enabled) {
        _adbStatusKey = 'adb_disconnected';
        _isConnecting = false;
      } else {
        _adbStatusKey = 'adb_waiting';
      }
    });
  }

  /// Simulates connecting to a target ADB device.
  /// 模拟连接到目标 ADB 设备。
  Future<void> _connectToDevice() async {
    if (!_wirelessEnabled) {
      _showToast(t('wireless_debugging_hint'), isError: true);
      return;
    }
    final ip = _ipController.text.trim();
    final port = _portController.text.trim();

    if (ip.isEmpty) {
      _showToast(t('adb_enter_ip'), isError: true);
      return;
    }
    if (port.isEmpty) {
      _showToast(t('adb_enter_port'), isError: true);
      return;
    }
    final parsedPort = int.tryParse(port);
    if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
      _showToast(t('invalid_port'), isError: true);
      return;
    }

    HapticFeedback.mediumImpact();
    setState(() => _isConnecting = true);

    /// Simulate a connection delay.
    /// 模拟连接延迟。
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    setState(() {
      _isConnecting = false;
      _adbStatusKey = 'adb_connected_to';
      _connectedDevices.removeWhere((d) => d.ip == ip && d.port == port);
      _connectedDevices.insert(
        0,
        _MockAdbDevice(
          ip: ip,
          port: port,
          deviceName: t('target_device'),
          status: 'online',
        ),
      );
    });
    _showToast(t('adb_connected_to').replaceAll('{0}', '$ip:$port'));
  }

  /// Shows a dialog with mock output for the given ADB command.
  /// 显示给定 ADB 命令的模拟输出对话框。
  void _showCommandOutput(String command) {
    final cs = Theme.of(context).colorScheme;
    HapticFeedback.lightImpact();
    final output = _generateMockAdbOutput(command);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text(
          command,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.jetBrainsMono(color: cs.primary, fontSize: 14),
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 280,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  output,
                  style: GoogleFonts.jetBrainsMono(
                    color: cs.onSurface,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              t('close'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.secondary),
            ),
          ),
        ],
      ),
    );
  }

  /// Generates realistic mock ADB command output.
  /// 生成逼真的模拟 ADB 命令输出。
  String _generateMockAdbOutput(String command) {
    switch (command) {
      case 'adb devices':
        return 'List of devices attached\n'
            '192.168.1.101:5555\tdevice\n'
            '192.168.1.102:5555\tdevice\n\n'
            '2 devices connected.';
      case 'adb install xxx.apk':
        return 'Performing Streamed Install\n'
            'adb: filename: app-release.apk\n'
            'Success';
      case 'adb shell screencap':
        return 'Screenshot saved to /sdcard/screenshot_'
            '${DateTime.now().millisecondsSinceEpoch}.png\n'
            'Resolution: 1080 x 2400\n'
            'File size: 1.8 MB';
      case 'adb reboot':
        return 'Rebooting device...\n'
            'Device will restart in approximately 30 seconds.\n'
            'Please wait for the device to come back online.';
      case 'adb logcat':
        final now = DateTime.now();
        final lines = <String>[];
        for (var i = 0; i < 15; i++) {
          final ts = now.subtract(Duration(seconds: i * 2));
          final t =
              '${ts.hour.toString().padLeft(2, '0')}:'
              '${ts.minute.toString().padLeft(2, '0')}:'
              '${ts.second.toString().padLeft(2, '0')}.${ts.millisecond.toString().padLeft(3, '0')}';
          lines.add(
            '$t  ${1000 + i}  ${2000 + i} '
            '${i % 3 == 0
                ? 'E'
                : i % 2 == 0
                ? 'W'
                : 'I'} '
            'ActivityManager: '
            '${i % 3 == 0
                ? 'ANR'
                : i % 2 == 0
                ? 'Slow operation'
                : 'Displayed'} '
            'com.nekomux/.MainActivity: +${i * 47}ms',
          );
        }
        return '--------- beginning of system\n${lines.join('\n')}';
      default:
        return 'Command executed successfully.';
    }
  }

  /// Displays a brief toast message.
  /// 显示简短提示消息。
  void _showToast(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      drawer: const AppDrawer(currentModule: 'adb', isTopLevel: true),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: Icon(Icons.menu, color: cs.onSurface.withValues(alpha: 0.6)),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Text(
          t('wireless_adb'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          /// Section: ADB status card.
          /// 板块：ADB 状态卡片。
          _buildSectionHeader('ADB ${t('status')}'),
          _buildStatusCard(),
          _buildNoticeCard(),

          /// Section: toggle wireless debugging.
          /// 板块：无线调试开关。
          _buildSectionHeader(t('wireless_debugging')),
          _buildWirelessToggle(),

          /// Section: target device input.
          /// 板块：目标设备输入。
          _buildSectionHeader(t('target_device')),
          _buildTargetDeviceInput(),

          /// Section: connected devices.
          /// 板块：已连接设备。
          _buildSectionHeader(t('connected_devices')),
          if (_connectedDevices.isEmpty)
            _buildEmptyDeviceCard()
          else
            ..._connectedDevices.map(_buildDeviceTile),

          /// Section: quick ADB commands.
          /// 板块：快捷 ADB 命令。
          _buildSectionHeader(t('quick_commands')),
          ..._adbCommands.map(_buildCommandCard),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Builds a section header with consistent styling.
  /// 构建样式统一的板块标题。
  Widget _buildSectionHeader(String title) {
    return AppSectionHeader(
      title: title,
      color: Theme.of(context).colorScheme.secondary,
    );
  }

  /// Builds the ADB connection status card with colored indicator.
  /// 构建带有彩色指示器的 ADB 连接状态卡片。
  Widget _buildStatusCard() {
    final cs = Theme.of(context).colorScheme;
    final statusText =
        _adbStatusKey == 'adb_connected_to' && _connectedDevices.isNotEmpty
        ? t(_adbStatusKey).replaceAll(
            '{0}',
            '${_connectedDevices.first.ip}:${_connectedDevices.first.port}',
          )
        : t(_adbStatusKey);
    final isConnected = _adbStatusKey == 'adb_connected_to';
    final statusColor = isConnected ? cs.primary : cs.error;
    final statusIcon = isConnected ? Icons.link : Icons.link_off;

    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          /// Colored status dot with shadow glow effect.
          /// 带阴影光晕的彩色状态圆点。
          AppIconBox(icon: statusIcon, color: statusColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ADB ${t('status')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeCard() {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      color: cs.secondary.withValues(alpha: 0.08),
      borderColor: cs.secondary.withValues(alpha: 0.18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: cs.secondary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              t('adb_mock_notice'),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.62),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the wireless debugging toggle row with instructions.
  /// 构建无线调试开关行及说明文本。
  Widget _buildWirelessToggle() {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      onTap: () => _toggleWirelessDebugging(!_wirelessEnabled),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  t('enable_wireless_debugging'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Switch(
                value: _wirelessEnabled,
                activeThumbColor: cs.primary,
                activeTrackColor: cs.primary.withValues(alpha: 0.3),
                inactiveThumbColor: cs.onSurface.withValues(alpha: 0.6),
                inactiveTrackColor: Theme.of(
                  context,
                ).dividerColor.withValues(alpha: 0.4),
                onChanged: _toggleWirelessDebugging,
              ),
            ],
          ),
          Text(
            t('wireless_debugging_hint'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.56),
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the target device IP + port input row with connect button.
  /// 构建目标设备 IP + 端口输入行及连接按钮。
  Widget _buildTargetDeviceInput() {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              /// IP address input.
              /// IP 地址输入框。
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _ipController,
                  enabled: _wirelessEnabled && !_isConnecting,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontFamily: 'monospace',
                  ),
                  cursorColor: cs.secondary,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: t('ip_address'),
                    labelStyle: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                    hintText: '192.168.1.100',
                    hintStyle: TextStyle(
                      color: cs.onSurface
                          .withValues(alpha: 0.6)
                          .withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: Theme.of(context).scaffoldBackgroundColor,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: Theme.of(context).dividerColor,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: cs.secondary),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),

              /// Port input.
              /// 端口输入框。
              SizedBox(
                width: 72,
                child: TextField(
                  controller: _portController,
                  enabled: _wirelessEnabled && !_isConnecting,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontFamily: 'monospace',
                  ),
                  cursorColor: cs.secondary,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t('port'),
                    labelStyle: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                    filled: true,
                    fillColor: Theme.of(context).scaffoldBackgroundColor,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: Theme.of(context).dividerColor,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: cs.secondary),
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          /// Connect button.
          /// 连接按钮。
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: Theme.of(context).scaffoldBackgroundColor,
                disabledBackgroundColor: cs.primary.withValues(alpha: 0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: _wirelessEnabled && !_isConnecting
                  ? _connectToDevice
                  : null,
              child: _isConnecting
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).scaffoldBackgroundColor,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.link, size: 18),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            t('connect'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyDeviceCard() {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Icon(
            Icons.phonelink_off_outlined,
            color: cs.onSurface.withValues(alpha: 0.42),
            size: 34,
          ),
          const SizedBox(height: 10),
          Text(
            t('no_connected_devices'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  /// Builds a tile for a connected ADB device.
  /// 构建设备列表项。
  Widget _buildDeviceTile(_MockAdbDevice device) {
    final cs = Theme.of(context).colorScheme;
    final address = '${device.ip}:${device.port}';
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          AppIconBox(icon: Icons.phone_android, color: cs.primary, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.jetBrainsMono(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  device.deviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          AppBadge(label: t('connected'), color: cs.primary),
        ],
      ),
    );
  }

  /// Builds a tappable command card that shows mock output in a dialog.
  /// 构建可点击的命令卡片，点击后在弹窗中显示模拟输出。
  Widget _buildCommandCard(_AdbCommand cmd) {
    final cs = Theme.of(context).colorScheme;
    final enabled = _connectedDevices.isNotEmpty;
    final iconColor = enabled
        ? cs.secondary
        : cs.onSurface.withValues(alpha: 0.32);
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      onTap: enabled ? () => _showCommandOutput(cmd.command) : null,
      color: enabled ? null : cs.onSurface.withValues(alpha: 0.035),
      child: Row(
        children: [
          AppIconBox(icon: cmd.icon, color: iconColor, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t(cmd.labelKey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: enabled
                        ? cs.onSurface
                        : cs.onSurface.withValues(alpha: 0.46),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  cmd.command,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: enabled
                        ? cs.primary.withValues(alpha: 0.8)
                        : cs.onSurface.withValues(alpha: 0.34),
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          Icon(
            enabled ? Icons.chevron_right : Icons.lock_outline,
            color: cs.onSurface.withValues(alpha: enabled ? 0.6 : 0.28),
            size: 20,
          ),
        ],
      ),
    );
  }
}

// ---- Helper classes / 辅助类 ----

/// Command definition for a quick ADB command card.
/// 快捷 ADB 命令卡片的命令定义。
class _AdbCommand {
  final String command;
  final String labelKey;
  final IconData icon;

  const _AdbCommand({
    required this.command,
    required this.labelKey,
    required this.icon,
  });
}

/// List of predefined quick ADB commands.
/// 预定义的快捷 ADB 命令列表。
const List<_AdbCommand> _adbCommands = [
  _AdbCommand(
    command: 'adb devices',
    labelKey: 'adb_cmd_devices',
    icon: Icons.devices,
  ),
  _AdbCommand(
    command: 'adb install xxx.apk',
    labelKey: 'adb_cmd_install',
    icon: Icons.install_mobile,
  ),
  _AdbCommand(
    command: 'adb shell screencap',
    labelKey: 'adb_cmd_screenshot',
    icon: Icons.screenshot_monitor,
  ),
  _AdbCommand(
    command: 'adb reboot',
    labelKey: 'adb_cmd_reboot',
    icon: Icons.restart_alt,
  ),
  _AdbCommand(
    command: 'adb logcat',
    labelKey: 'adb_cmd_logcat',
    icon: Icons.terminal,
  ),
];

/// Data class for a mock connected ADB device.
/// 模拟已连接 ADB 设备的数据类。
class _MockAdbDevice {
  final String ip;
  final String port;
  final String deviceName;
  final String status;

  const _MockAdbDevice({
    required this.ip,
    required this.port,
    required this.deviceName,
    required this.status,
  });
}
