# On-device integration tests / 真机集成测试

These tests run **on a real phone** against a **real SSH server**. They exist to
answer the one question unit tests cannot: does a file survive the trip through
the device's network stack, the real `dartssh2` client, and a real
`sftp-server`, byte for byte?

这些测试在**真机**上针对**真实 SSH 服务器**运行。它们回答单元测试无法回答的唯一问题：
文件能否经过设备网络栈、真实的 `dartssh2` 客户端与真实的 `sftp-server`，一字节不差地
走个来回。

## Why not just `flutter test` / 为什么不放进 `flutter test`

`flutter test` runs everything under `test/` with faked sessions — fast,
deterministic, no network. That is the right default and it stays the default.
These tests need a server, a device and a tunnel, so they live outside `test/`
and only run when asked for explicitly.

`flutter test` 会运行 `test/` 下所有测试，会话全部伪造——快速、确定、不依赖网络。
这是正确的默认值，也将一直是默认值。这些测试需要服务器、设备与隧道，因此放在 `test/`
之外，只在你明确要求时运行。

## Running them / 运行方式

1. Start the test servers / 启动测试服务器:

   ```bash
   # The transfer fixture, and the target the batch suite needs a SECOND of:
   # two answers can only be told apart when two machines give them.
   docker start nekomux-test-ssh      # publishes 127.0.0.1:2222
   docker start nekomux-test-ssh-2    # publishes 127.0.0.1:2223, -h neko-target
   ```

   The second one is created once with:

   ```bash
   docker run -d --name nekomux-test-ssh-2 -h neko-target \
     -e PUID=1000 -e PGID=1000 -e USER_NAME=nekotest -e USER_PASSWORD=nekotest \
     -e PASSWORD_ACCESS=true -e SUDO_ACCESS=false \
     -p 127.0.0.1:2223:2222 lscr.io/linuxserver/openssh-server:latest
   ```

   Both need `AllowTcpForwarding yes` in `/config/sshd/sshd_config` — note that
   the linuxserver image runs `sshd -f /config/sshd/sshd_config`, NOT
   `/etc/ssh/sshd_config`, and a change to the wrong file looks exactly like a
   change that did not take effect.

2. Tunnel them to the phone / 把隧道打到手机上:

   ```bash
   adb reverse tcp:2222 tcp:2222
   adb reverse tcp:2223 tcp:2223   # the batch suite's second host
   ```

3. Create the fixtures the download tests read (once) / 准备下载测试所需的夹具（一次）:

   ```bash
   sshpass -p nekotest ssh -p 2222 nekotest@127.0.0.1 \
     'mkdir -p ~/fixtures && head -c 200000 /dev/urandom > ~/fixtures/rand200k.bin'

   # The nested tree the folder-download suite reproduces, empty directory and
   # all: the empty one is what proves the scan reports what it could not carry.
   sshpass -p nekotest ssh -p 2222 nekotest@127.0.0.1 '
     rm -rf /config/tree &&
     mkdir -p /config/tree/app/logs /config/tree/conf /config/tree/empty &&
     echo "top level" > /config/tree/readme.txt &&
     head -c 150000 /dev/urandom > /config/tree/app/big.bin &&
     echo "day one" > /config/tree/app/logs/day1.txt &&
     echo "day two" > /config/tree/app/logs/day2.txt &&
     printf "server_name x;\n" > /config/tree/conf/nginx.conf'
   ```

4. Run / 运行:

   ```bash
   flutter test integration_test/transfer_roundtrip_test.dart -d <device-id>
   ```

## What it checks / 检查内容

| Suite | What it covers |
| --- | --- |
| `transfer_roundtrip_test.dart` | bytes through the real network stack, both directions, plus a tunnel |
| `batch_exec_test.dart` | one command on two real servers; each answers for itself, and neither a dead host nor a failing command stops the rest |
| `jump_host_test.dart` | a target this phone cannot route to, reached through a bastion — with the premise asserted, so the test cannot stop proving anything |
| `folder_download_test.dart` | a whole folder's tree reproduced on the device, file for file, with the empty directory reported |
| `disk_probe_test.dart` | the `df` command and parser against a real server's own output, not a fixture |
| `command_session_test.dart` | a PTY session running a command: its output, its input path, and that a plain session is still a login shell |
| `container_create_test.dart` | the built `docker run` reaching a real shell as separate arguments, and a host without Docker being reported as a failure |
| `container_detail_test.dart` | the `docker inspect` template reaching a real shell byte for byte, and a host without Docker failing rather than rendering an empty container |

| Test | What a failure means |
| --- | --- |
| reaches the test server | the tunnel or the server is down, not the app |
| a file the app never wrote downloads intact | truncating or reordering reads |
| upload then download is byte-identical | corruption in either direction |
| an empty file survives both directions | a completion path that waits for "some bytes" |

None of these need a screenshot: they assert on bytes, so they can be run and
trusted on a headless machine.

这些测试都不需要截图：它们直接对字节断言，因此在无人值守的机器上也能运行并采信。

## The half a device test cannot reach / 真机测试够不到的那一半

`container_create_test.dart` proves the built `docker run` reaches a real shell
as separate arguments. It cannot prove a daemon *accepts* it: the fixture has no
Docker, and asserting against a fake daemon would prove nothing. That half is
checked by hand, and it is worth re-running after any change to
`buildDockerRun`.

The command is taken from the app rather than retyped, so what gets checked is
what ships:

```bash
dart --packages=.dart_tool/package_config.json tool/print_run_command.dart
```

Run what it prints, then read back what the daemon recorded. Each field below is
one the form asked for, so each is an assertion, not a description:

```bash
docker inspect --format 'name={{.Name}} image={{.Config.Image}} restart={{.HostConfig.RestartPolicy.Name}}' nekomux-verify-command
docker inspect --format 'port={{range $p, $b := .HostConfig.PortBindings}}{{$p}}->{{range $b}}{{.HostIp}}:{{.HostPort}}{{end}}{{end}}' nekomux-verify-command
docker inspect --format 'env={{range .Config.Env}}{{.}} {{end}}' nekomux-verify-command
docker rm -f nekomux-verify-command
```

`container_create_test.dart` 证明构造出的 `docker run` 能作为独立参数到达真实
shell；它无法证明守护进程**接受**这条命令——夹具里没有 Docker，而对一个假守护进程
断言什么都证明不了。这一半靠手工校验，对 `buildDockerRun` 的任何改动之后都值得重跑。

命令取自应用本身而非重新敲一遍，因此被校验的就是真正发布的那个。

## Note / 注意

The test build shares the app's `applicationId`, so running these **replaces the
installed release build** on the device. Reinstall the release APK afterwards if
you want the phone back on it.

测试构建与应用共用 `applicationId`，因此运行它们会**替换设备上已安装的 release 版本**。
若想让手机回到 release 版本，之后重新安装一次 APK 即可。
