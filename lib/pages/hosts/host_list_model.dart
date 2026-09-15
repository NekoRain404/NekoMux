// Display model of the home screen's host list: search, grouping, and how the
// two compose with the three reachability states.
// 主页主机列表的展示模型：搜索、分组，以及二者与三种可达性状态的组合方式。
//
// Everything here is a pure function over a `List<Host>`, deliberately free of
// Flutter and of providers, so the parts worth getting right — which hosts a
// query selects, which group a host lands in, whether the numbers still add up
// — are pinned by unit tests instead of only being observable by scrolling a
// phone.
// 这里的一切都是作用在 `List<Host>` 上的纯函数，刻意不依赖 Flutter 与 provider，
// 因此真正值得做对的部分——查询选中了哪些主机、主机落在哪个分组、数字是否仍然对得上
// ——可以由单元测试固定，而不是只能靠在一台手机上滚动来观察。
import '../../models/host.dart';

/// Number of hosts from which the home screen offers a search field.
/// 主页从多少台主机起提供搜索框。
///
/// Eight, because that is where this screen stops fitting on a phone: the
/// overview card plus a section header take the first screenful, so a list
/// shorter than this is one the user can take in at a glance, and a permanent
/// search box would cost the top of every launch to help nobody. A dozen hosts
/// — the size at which the flat list became unusable — is comfortably past it.
/// 取 8，因为屏幕到这时才装不下：摘要卡加上分组标题已占去第一屏，短于此的列表用户
/// 一眼就能看完，而常驻的搜索框会在每次启动时占着顶部却帮不到任何人。一打主机——
/// 也就是这份平铺列表开始不好用的规模——则稳稳在这条线之上。
const int kHostSearchMinHosts = 8;

/// The order the three sections appear in: online, unverified, offline.
/// 三个分组的显示顺序：在线、待验证、离线。
///
/// Spelled out instead of using `HostStatus.values`, whose order is the order
/// the enum happened to be declared in — a fact about a file in `models/`, not
/// a decision about this screen, and one an unrelated edit could silently
/// reorder. Online leads because the usable hosts are what the user came for;
/// unverified sits in the middle, next to neither answer it refuses to give.
/// 明确写出而非使用 `HostStatus.values`：后者的顺序只是枚举碰巧的声明顺序——那是
/// `models/` 里某个文件的事实，不是本页面的决定，一次无关的修改就可能悄悄改变它。
/// 在线居首，因为用户打开这一页是为了能用的主机；待验证居中，它拒绝给出的两个答案
/// 都不挨着。
const List<HostStatus> hostSectionOrder = [
  HostStatus.online,
  HostStatus.unverified,
  HostStatus.offline,
];

/// Whether the home screen should show its search field.
/// 主页是否应显示搜索框。
///
/// [hostCount] is the size of the whole list, not of a filtered view: the
/// question is whether this list needs a way to search it, which does not
/// change while the user is typing.
/// [hostCount] 是整个列表的规模，而非过滤后视图的规模：这里问的是这份列表是否需要
/// 一个搜索入口，而这一点在用户输入过程中不会改变。
///
/// A non-empty [query] keeps the field on screen whatever the count is. Without
/// that, filtering the list down below the threshold would make the field
/// disappear along with the text that is filtering it — leaving the user
/// looking at a handful of hosts, with no visible reason why, and no way back.
/// 只要 [query] 非空，无论数量多少，输入框都留在屏幕上。否则，把列表过滤到阈值以下
/// 会让输入框连同过滤它的那段文字一起消失——用户对着一小撮主机，看不到任何原因，
/// 也没有退路。
bool shouldOfferSearch({required int hostCount, required String query}) =>
    hostCount >= kHostSearchMinHosts || query.trim().isNotEmpty;

/// Whether [host] matches the free-text [query].
/// [host] 是否匹配自由文本 [query]。
///
/// Matches what a host card actually shows: the alias, the address (both the
/// raw one and [Host.displayAddress], which carries the port when it is not
/// 22), and the credential's username. Case-insensitive, substring, so "prod"
/// finds "prod-web-1" and "10.0" finds "10.0.0.5".
/// 匹配主机卡片上真正显示的内容：别名、地址（原始地址与带端口的
/// [Host.displayAddress]，端口非 22 时会带上端口），以及凭据的用户名。大小写不敏感、
/// 子串匹配，因此 "prod" 能找到 "prod-web-1"，"10.0" 能找到 "10.0.0.5"。
///
/// The group name is deliberately *not* searched. The search hint tells the user
/// what this field covers — "name, address or username" in all eight languages
/// — and a field that also matched groups would make that hint a lie the moment
/// it surprised someone.
/// 刻意**不**搜索分组名。搜索提示词已经告诉用户这个输入框覆盖什么——八种语言里都是
/// 「名称、地址或用户名」——一个还匹配分组名的输入框会在让某人意外的瞬间让那句话变成
/// 假话。
bool hostMatchesQuery(Host host, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  if (host.alias.toLowerCase().contains(needle)) return true;
  if (host.ipAddress.toLowerCase().contains(needle)) return true;
  if (host.displayAddress.toLowerCase().contains(needle)) return true;
  final username = host.credentialUsername;
  if (username != null && username.toLowerCase().contains(needle)) return true;
  return false;
}

/// The hosts of [hosts] that match [query], keeping their incoming order.
/// [hosts] 中匹配 [query] 的主机，保持原有顺序。
List<Host> filterHosts(List<Host> hosts, String query) => [
  for (final host in hosts)
    if (hostMatchesQuery(host, query)) host,
];

/// One group's worth of hosts: a name, and the hosts carrying it.
/// 一个分组的主机：一个分组名，以及带有该名的那些主机。
class HostGroup {
  /// The group name, or `null` for hosts with no group.
  /// 分组名；未分组的主机为 `null`。
  ///
  /// `null` is a group like any other here — "ungrouped" hosts are a bucket,
  /// not a leftover — which is why the class keeps them instead of the UI
  /// having to special-case them back in.
  /// 在此 `null` 与其它分组无异——「未分组」的主机是一个分桶，不是剩余物——因此本类
  /// 保留它们，而不是让界面再把它们特例化地加回来。
  final String? name;

  final List<Host> hosts;

  const HostGroup({required this.name, required this.hosts});
}

/// One reachability state's worth of the list: its hosts, split by group.
/// 列表中某个可达性状态的部分：它的主机，按分组切分。
class HostSection {
  final HostStatus status;

  /// The groups inside this section, in display order. Ungrouped hosts are the
  /// group whose [HostGroup.name] is `null`.
  /// 本分组内的各个分组，按显示顺序排列。未分组的主机即 [HostGroup.name] 为 `null`
  /// 的那一组。
  final List<HostGroup> groups;

  const HostSection({required this.status, required this.groups});

  /// Number of hosts in this section.
  /// 本分组中的主机数。
  int get count => groups.fold(0, (sum, group) => sum + group.hosts.length);

  /// The section's hosts in display order.
  /// 本分组按显示顺序排列的主机。
  List<Host> get hosts => [for (final group in groups) ...group.hosts];
}

/// Splits [hosts] into the home screen's display model: the three reachability
/// sections, in the order they are shown, each with its hosts grouped by
/// `groupName` and filtered by [query].
/// 把 [hosts] 切分为主页的展示模型：三个可达性分组，按显示顺序排列，各分组内的主机按
/// `groupName` 分组并已由 [query] 过滤。
///
/// **Status is the outer level and the group is the inner one.** The three-state
/// split is this screen's primary statement — it is what the overview card
/// counts, what the section headers announce, and what the page was rebuilt
/// around when the old boolean could not tell "down" from "not checked". Making
/// groups the outer level would put a 生产 section above an 在线 one and quietly
/// demote exactly that distinction to a sub-heading; it would also multiply the
/// headers (nine for three groups) and scatter the unverified hosts — the ones
/// the user can act on — into every group. The group is the finer of the two
/// facts: "this host is in production" narrows down a set that "this host is
/// offline" has already established, not the other way round.
/// **状态是外层，分组是内层。** 三态切分是本页最主要的陈述——摘要卡数的是它，分组标题
/// 宣布的是它，旧布尔值分不清「宕机」与「未检查」时整个页面也是围绕它重建的。把分组
/// 放到外层，会让「生产」分组排在「在线」之上，把这一区分悄悄降级为子标题；还会让标题
/// 数量成倍增加（三个分组就是九个），并把「待验证」——恰恰是用户可以行动的那一类——
/// 打散到每个分组里。分组是两个事实中更细的那个：「这台在生成环境」缩小的是「这台离线」
/// 已经界定的集合，而不是反过来。
///
/// Sections with no matching hosts are still returned, so the caller can render
/// headers, counts and empty states from one list without re-deriving anything;
/// callers that only want the populated ones check [HostSection.count].
/// 没有匹配主机的分组仍会被返回，调用方因此可以从同一份列表渲染标题、计数与空状态，
/// 无需重新推导；只想要非空分组的调用方检查 [HostSection.count] 即可。
List<HostSection> buildHostSections(List<Host> hosts, String query) {
  final matched = filterHosts(hosts, query);
  return [
    for (final status in hostSectionOrder)
      HostSection(
        status: status,
        groups: groupHosts([
          for (final host in matched)
            if (host.status == status) host,
        ]),
      ),
  ];
}

/// Splits [hosts] into named groups plus one ungrouped bucket.
/// 把 [hosts] 切分为若干具名分组外加一个未分桶。
///
/// Named groups come first, sorted case-insensitively so the order does not
/// depend on the language or on which host happened to be added first;
/// ungrouped hosts come last. A named group is a statement the user made about
/// those hosts, and the ungrouped bucket is the absence of one — reading it
/// first would put every host the user has not classified yet above the ones
/// they have. Within a group the incoming order (alias, from the database) is
/// kept, so a group never reshuffles itself between rebuilds.
/// 具名分组在前，按大小写不敏感排序，使顺序不取决于语言、也不取决于哪台主机先被添加；
/// 未分组的主机在最后。具名分组是用户对那些主机做出的陈述，未分桶则是陈述的缺席——
/// 把它排在最前，会让用户尚未归类的主机压在他们已经归类的主机之上。分组内部保持原有
/// 顺序（来自数据库的别名顺序），因此分组不会在多次重建之间自行重排。
List<HostGroup> groupHosts(List<Host> hosts) {
  final byName = <String, List<Host>>{};
  final ungrouped = <Host>[];
  for (final host in hosts) {
    final name = Host.normalizeGroupName(host.groupName);
    if (name == null) {
      ungrouped.add(host);
    } else {
      (byName[name] ??= <Host>[]).add(host);
    }
  }

  final names = byName.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  return [
    for (final name in names) HostGroup(name: name, hosts: byName[name]!),
    if (ungrouped.isNotEmpty) HostGroup(name: null, hosts: ungrouped),
  ];
}

/// Whether group headers are worth drawing for [sections].
/// 是否为 [sections] 绘制分组标题。
///
/// Only when what is on screen actually spans more than one group. With every
/// host in one bucket — the common case for a user who has never grouped
/// anything — a lone "no group" header above every section is pure noise, and it
/// would teach the user to ignore the header that does carry information.
/// The count is taken over the *visible* hosts, so a search that narrows the
/// list to a single group also drops a header that no longer distinguishes
/// anything.
/// 只有当屏幕上确实跨越多个分组时才绘制。所有主机同属一桶时——对从未分过组的用户
/// 而言这是常态——每个分组上方孤零零一条「未分组」纯属噪音，还会教用户忽略那些确实
/// 携带信息的标题。计数取自**可见**主机，因此把列表收窄到单一分组的搜索同样会去掉
/// 一个不再区分任何东西的标题。
bool shouldShowGroupHeaders(List<HostSection> sections) {
  final names = <String?>{};
  for (final section in sections) {
    for (final group in section.groups) {
      if (group.hosts.isEmpty) continue;
      names.add(group.name);
      if (names.length > 1) return true;
    }
  }
  return false;
}

/// The group names already in use across [hosts], sorted, for offering as
/// suggestions in the add/edit form.
/// [hosts] 中已在使用的分组名，已排序，供新增/编辑表单作为建议提供。
///
/// This is what keeps a typo from splitting one group into two: the user picks
/// a name that exists instead of retyping it. Blank values are not offered —
/// "no group" is already the default state of the field.
/// 这正是防止一个错别字把同一分组劈成两个的东西：用户挑一个已存在的名字，而不是重新
/// 输入一遍。空白值不予提供——「不分组」本就是输入框的默认状态。
List<String> existingGroupNames(List<Host> hosts) {
  final names = <String>{};
  for (final host in hosts) {
    final name = Host.normalizeGroupName(host.groupName);
    if (name != null) names.add(name);
  }
  return names.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}
