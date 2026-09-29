import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/app_fonts.dart';
import '../../widgets/form_fields.dart';
import 'docker_run_spec.dart';

/// The form for creating a container: what `docker run` needs, and nothing else.
///
/// It returns a [DockerRunSpec] rather than running anything — the page that
/// owns the SSH connection is the one that executes, so this stays a form. The
/// command is built from the spec by [buildDockerRun], which is where the
/// quoting lives and where it is tested; nothing here concatenates a command
/// line, and that separation is deliberate: a form that built its own command
/// would be a second, untested path from a text field to a remote shell.
class NewContainerPage extends StatefulWidget {
  const NewContainerPage({super.key});

  @override
  State<NewContainerPage> createState() => _NewContainerPageState();
}

class _NewContainerPageState extends State<NewContainerPage> {
  final _formKey = GlobalKey<FormState>();
  final _image = TextEditingController();
  final _name = TextEditingController();
  final _ports = TextEditingController();
  final _volumes = TextEditingController();
  final _environment = TextEditingController();
  final _extra = TextEditingController();
  String _restartPolicy = 'unless-stopped';

  @override
  void dispose() {
    _image.dispose();
    _name.dispose();
    _ports.dispose();
    _volumes.dispose();
    _environment.dispose();
    _extra.dispose();
    super.dispose();
  }

  /// Splits a multi-line field into entries, one per line.
  ///
  /// One per line rather than comma-separated: a volume path or an environment
  /// value can contain a comma, and a form that split on it would silently turn
  /// one mount into two.
  List<String> _lines(TextEditingController controller) => [
    for (final line in controller.text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final spec = DockerRunSpec(
      image: _image.text.trim(),
      name: _name.text.trim(),
      ports: _lines(_ports),
      volumes: _lines(_volumes),
      environment: _lines(_environment),
      restartPolicy: _restartPolicy,
      extraArgs: _extra.text.trim(),
    );

    // Built here so an unsafe value is refused while the form is still on
    // screen, with the offending field still in front of the user — rather than
    // after the page has closed and the command has gone to a server.
    final plan = buildDockerRun(spec);
    if (!plan.isOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_problemText(plan)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    Navigator.pop(context, spec);
  }

  String _problemText(DockerRunPlan plan) => switch (plan.problem!) {
    DockerRunProblem.missingImage => t('container_need_image'),
    DockerRunProblem.unsafeValue => t(
      'container_unsafe_value',
    ).replaceAll('{0}', plan.offendingValue ?? ''),
    DockerRunProblem.malformedPair => t(
      'container_malformed_pair',
    ).replaceAll('{0}', plan.offendingValue ?? ''),
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: cs.surface,
        leading: IconButton(
          icon: Icon(
            Icons.close,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          t('container_new'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: _submit,
            child: Text(t('container_create'), style: TextStyle(color: cs.secondary)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AppFormField(
              controller: _image,
              label: t('container_image'),
              hint: t('container_image_hint'),
              monospace: true,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? t('container_need_image')
                  : null,
            ),
            const SizedBox(height: 14),
            AppFormField(
              controller: _name,
              label: t('container_name'),
              hint: t('container_name_hint'),
              monospace: true,
            ),
            const SizedBox(height: 14),
            AppFormField(
              controller: _ports,
              label: t('container_ports'),
              hint: t('container_ports_hint'),
              monospace: true,
              maxLines: 3,
            ),
            const SizedBox(height: 14),
            AppFormField(
              controller: _volumes,
              label: t('container_volumes'),
              hint: t('container_volumes_hint'),
              monospace: true,
              maxLines: 3,
            ),
            const SizedBox(height: 14),
            AppFormField(
              controller: _environment,
              label: t('container_env'),
              hint: t('container_env_hint'),
              monospace: true,
              maxLines: 3,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _restartPolicy,
              dropdownColor: cs.surface,
              style: TextStyle(color: cs.onSurface, fontSize: 14),
              decoration: InputDecoration(
                labelText: t('container_restart_policy'),
                labelStyle: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
                filled: true,
                fillColor: cs.surface,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final policy in const [
                  'unless-stopped',
                  'always',
                  'on-failure',
                  'no',
                ])
                  DropdownMenuItem(value: policy, child: Text(policy)),
              ],
              onChanged: (value) =>
                  setState(() => _restartPolicy = value ?? 'unless-stopped'),
            ),
            const SizedBox(height: 14),
            AppFormField(
              controller: _extra,
              label: t('container_extra_args'),
              hint: t('container_extra_args_hint'),
              monospace: true,
            ),
            const SizedBox(height: 20),
            // The exact command, shown before it is sent. A user about to create
            // something on a server should be able to read what will run — and
            // this is also the only way to see how a quoting decision came out.
            _CommandPreview(spec: _spec()),
          ],
        ),
      ),
    );
  }

  DockerRunSpec _spec() => DockerRunSpec(
    image: _image.text.trim().isEmpty ? '<image>' : _image.text.trim(),
    name: _name.text.trim(),
    ports: _lines(_ports),
    volumes: _lines(_volumes),
    environment: _lines(_environment),
    restartPolicy: _restartPolicy,
    extraArgs: _extra.text.trim(),
  );
}

/// The command line the form currently describes.
class _CommandPreview extends StatelessWidget {
  final DockerRunSpec spec;

  const _CommandPreview({required this.spec});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final plan = buildDockerRun(spec);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t('container_command_preview'),
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.5),
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: Text(
            plan.command ?? '—',
            style: TextStyle(
              color: plan.isOk ? cs.onSurface : cs.error,
              fontSize: 11,
              height: 1.5,
              fontFamily: AppFonts.mono,
            ),
          ),
        ),
      ],
    );
  }
}
