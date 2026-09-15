import 'data/de.dart';
import 'data/en.dart';
import 'data/es.dart';
import 'data/fr.dart';
import 'data/ja.dart';
import 'data/ko.dart';
import 'data/ru.dart';
import 'data/zh.dart';

/// Convenience shorthand for [AppStrings.get].
/// [AppStrings.get] 的便捷缩写。
String t(String key) => AppStrings.get(key);

/// Static localization class — no code generation needed.
/// 静态本地化类 — 无需代码生成。
///
/// The translation data itself lives one file per language under `data/`;
/// this file only wires it together and exposes the lookup API.
/// 翻译数据本身按语言拆分到 `data/` 目录下，每个语言一个文件；
/// 本文件只负责组装并提供查询 API。
class AppStrings {
  static String currentLang = 'zh';

  static void setLang(String lang) => currentLang = lang;

  /// Look up a string by key for the current language.
  /// 在当前语言下按键查找字符串。
  static String get(String key) => _strings[key]?[currentLang] ?? key;

  // ---- convenience getters ----
  static String get appName => get('app_name');
  static String get appDesc => get('app_desc');
  static String get myHosts => get('my_hosts');
  static String get onlineHosts => get('online_hosts');
  static String get offlineHosts => get('offline_hosts');
  static String get addHost => get('add_host');
  static String get editHost => get('edit_host');
  static String get hostAlias => get('host_alias');
  static String get ipAddress => get('ip_address');
  static String get port => get('port');
  static String get osType => get('os_type');
  static String get credential => get('credential');
  static String get save => get('save');
  static String get cancel => get('cancel');
  static String get confirm => get('confirm');
  static String get delete => get('delete');
  static String get edit => get('edit');
  static String get testConn => get('test_conn');
  static String get testing => get('testing');
  static String get connSuccess => get('conn_success');
  static String get connFailed => get('conn_failed');
  static String get connTimeout => get('conn_timeout');
  static String get authFailed => get('auth_failed');
  static String get connRefused => get('conn_refused');
  static String get hostUnreachable => get('host_unreachable');
  static String get credentials => get('credentials');
  static String get snippets => get('snippets');
  static String get settings => get('settings');
  static String get about => get('about');
  static String get terminal => get('terminal');
  static String get fileManager => get('file_manager');
  static String get remoteDesktop => get('remote_desktop');
  static String get dockerMonitor => get('docker_monitor');
  static String get localShell => get('local_shell');
  static String get wirelessAdb => get('wireless_adb');
  static String get darkMode => get('dark_mode');
  static String get lightMode => get('light_mode');
  static String get hapticFeedback => get('haptic_feedback');
  static String get language => get('language');
  static String get theme => get('theme');
  static String get font => get('font');
  static String get exportBackup => get('export_backup');
  static String get restoreBackup => get('restore_backup');
  static String get clearData => get('clear_data');
  static String get connecting => get('connecting');
  static String get connected => get('connected');
  static String get disconnected => get('disconnected');
  static String get reconnect => get('reconnect');
  static String get copy => get('copy');
  static String get copied => get('copied');
  static String get refresh => get('refresh');
  static String get retry => get('retry');
  static String get noData => get('no_data');
  static String get loading => get('loading');
  static String get error => get('error');
  static String get hostKeyVerify => get('host_key_verify');
  static String get accept => get('accept');
  static String get reject => get('reject');
  static String get batchDelete => get('batch_delete');
  static String get selected => get('selected');
  static String get rename => get('rename');
  static String get download => get('download');
  static String get chmod => get('chmod');
  static String get newFile => get('new_file');
  static String get upload => get('upload');
  static String get modules => get('modules');
  static String get tools => get('tools');
  static String get system => get('system');
  static String get appearance => get('appearance');
  static String get connection => get('connection');
  static String get interaction => get('interaction');
  static String get data => get('data');
  static String get hostDetail => get('host_detail');
  static String get resourceMonitor => get('resource_monitor');
  static String get functionModules => get('function_modules');
  static String get emptyHosts => get('empty_hosts');
  static String get emptyHostsHint => get('empty_hosts_hint');
  static String get emptyCreds => get('empty_creds');
  static String get emptySnippets => get('empty_snippets');
  static String get manageCredentials => get('manage_credentials');
  static String get manageSnippets => get('manage_snippets');
  static String get switchView => get('switch_view');
  static String get selectCredential => get('select_credential');
  static String get addCredential => get('add_credential');
  static String get editCredential => get('edit_credential');
  static String get placeholderDesc => get('placeholder_desc');
  // New additions — process & service management / 新增 — 进程与服务管理
  static String get processManager => get('process_manager');
  static String get serviceManager => get('service_manager');
  static String get killProcess => get('kill_process');
  static String get systemdStart => get('systemd_start');
  static String get systemdStop => get('systemd_stop');
  static String get systemdRestart => get('systemd_restart');
  static String get systemdEnable => get('systemd_enable');
  static String get systemdDisable => get('systemd_disable');
  static String get systemdReload => get('systemd_reload');
  static String get filterAll => get('filter_all');
  static String get filterRunning => get('filter_running');
  static String get filterFailed => get('filter_failed');
  static String get filterInactive => get('filter_inactive');
  static String get realTime => get('real_time');
  static String get simulatedData => get('simulated_data');
  // Additional keys used across pages / 跨页面使用的额外键
  static String get add => get('add');
  static String get hostAdded => get('host_added');
  static String get hostUpdated => get('host_updated');
  static String get credAdded => get('credential_added');
  static String get credUpdated => get('credential_updated');
  static String get credName => get('credential_name');
  static String get username => get('username');
  static String get password => get('password');
  static String get privateKey => get('private_key');
  static String get passwordAuth => get('password_auth');
  static String get keyAuth => get('key_auth');
  static String get authMethod => get('auth_method');
  static String get selectCredFirst => get('select_credential_first');
  static String get enterIpFirst => get('enter_ip_first');
  static String get credNotFound => get('credential_not_found');
  static String get credEncryptedNotice => get('credential_encrypted_notice');
  static String get keyFormatValid => get('key_format_valid');
  static String get confirmDelete => get('confirm_delete');
  static String get confirmDeleteCred => get('confirm_delete_credential');
  static String get confirmDeleteSnippet => get('confirm_delete_snippet');
  static String get emptyCredsHint => get('empty_creds_hint');
  static String get emptySnippetsHint => get('empty_snippets_hint');
  static String get snippetTitle => get('snippet_title');
  static String get snippetCommand => get('snippet_command');
  static String get addSnippet => get('add_snippet');
  static String get editSnippet => get('edit_snippet');
  static String get scrollUpMore => get('scroll_up_more');
  static String get resourceRefreshed => get('resource_refreshed');
  static String get running => get('running');
  static String get offlineStatus => get('offline_status');
  static String get recentSamples => get('recent_samples');
  static String get sshPort => get('ssh_port');
  static String get sftpProtocol => get('sftp_protocol');
  static String get processSubtitle => get('process_subtitle');
  static String get serviceSubtitle => get('service_subtitle');
  static String get mustSelectCred => get('must_select_credential');
  static String get addCredFirst => get('add_credential_first');
  static String get hostAliasHint => get('host_alias_hint');
  static String get ipAddressHint => get('ip_address_hint');
  static String get defaultPort => get('default_port');
  static String get credNameHint => get('credential_name_hint');
  static String get usernameHint => get('username_hint');
  static String get passwordHint => get('password_hint');
  static String get privateKeyHint => get('private_key_hint');
  static String get saveHost => get('save_host');
  static String get updateHost => get('update_host');
  static String get saveCred => get('save_credential');
  static String get updateCred => get('update_credential');
  static String get connSuccessDetail => get('conn_success_detail');
  static String get localShellSubtitle => get('local_shell_subtitle');
  static String get wirelessAdbSubtitle => get('wireless_adb_subtitle');
  static String get credentialsMenu => get('credentials_menu');
  static String get snippetsMenu => get('snippets_menu');
  static String get settingsMenu => get('settings_menu');
  static String get aboutMenu => get('about_menu');
  static String get myHostsMenu => get('my_hosts_menu');
  static String get localShellMenu => get('local_shell_menu');
  static String get wirelessAdbMenu => get('wireless_adb_menu');
  static String get keyInvalidFormat => get('key_invalid_format');
  static String get keyIncomplete => get('key_incomplete');
  static String get mustEnterName => get('must_enter_name');
  static String get mustEnterUsername => get('must_enter_username');
  static String get mustEnterPassword => get('must_enter_password');
  static String get mustEnterAlias => get('must_enter_alias');
  static String get mustEnterIp => get('must_enter_ip');
  static String get mustEnterSnippetTitle => get('must_enter_snippet_title');
  static String get mustEnterSnippetCommand =>
      get('must_enter_snippet_command');
  // Docker container management / Docker 容器管理
  static String get containers => get('containers');
  static String get start => get('start');
  static String get stop => get('stop');
  static String get restart => get('restart');
  static String get logs => get('logs');
  static String get containerShell => get('container_shell');
  static String get addContainer => get('add_container');
  static String get containerRunning => get('container_running');
  static String get containerStopped => get('container_stopped');
  static String get containerStartSuccess => get('container_start_success');
  static String get containerStopSuccess => get('container_stop_success');
  static String get containerRestartSuccess => get('container_restart_success');
  static String get containerRemoveSuccess => get('container_remove_success');
  static String get containerShellComingSoon =>
      get('container_shell_coming_soon');
  static String get containerAddComingSoon => get('container_add_coming_soon');
  static String get sshNotConnected => get('ssh_not_connected');
  static String get dockerNotInstalled => get('docker_not_installed');
  static String get loadingContainers => get('loading_containers');
  static String get fetchContainersFailed => get('fetch_containers_failed');
  static String get confirmRemoveContainer => get('confirm_remove_container');
  static String get removeContainer => get('remove_container');
  static String get noContainers => get('no_containers');
  static String get noContainersHint => get('no_containers_hint');
  static String get reconnecting => get('reconnecting');

  /// All supported language codes and their display names.
  /// 全対応言語コードとその表示名。
  static const Map<String, String> supportedLanguages = {
    'zh': '中文',
    'en': 'English',
    'ja': '日本語',
    'ko': '한국어',
    'fr': 'Français',
    'de': 'Deutsch',
    'ru': 'Русский',
    'es': 'Español',
  };

  /// The per-language translation tables, keyed by language code.
  /// 按语言代码索引的各语言翻译表。
  static const Map<String, Map<String, String>> _byLanguage = {
    'zh': zhStrings,
    'en': enStrings,
    'ja': jaStrings,
    'ko': koStrings,
    'fr': frStrings,
    'de': deStrings,
    'ru': ruStrings,
    'es': esStrings,
  };

  /// Inverted lookup table: key -> { language code -> text }.
  ///
  /// Built once from [_byLanguage] so the split layout keeps the exact
  /// original lookup semantics: a missing key (or a missing language for that
  /// key) still falls back to the key name itself.
  /// 由 [_byLanguage] 一次性构建的反向查找表，保证拆分后与原实现语义完全一致。
  static final Map<String, Map<String, String>> _strings = _invert();

  static Map<String, Map<String, String>> _invert() {
    final byKey = <String, Map<String, String>>{};
    for (final language in _byLanguage.entries) {
      for (final entry in language.value.entries) {
        (byKey[entry.key] ??= <String, String>{})[language.key] = entry.value;
      }
    }
    return byKey;
  }
}
