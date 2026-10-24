import 'package:flutter/material.dart';

import '../../models/railpack_runtime.dart';
import '../system/app_forms.dart';
import '../system/app_workspace.dart';

class CreateProjectRequest {
  const CreateProjectRequest({
    required this.name,
    required this.type,
    required this.gitUrl,
    required this.primaryDomain,
    required this.railpackRuntimeId,
    required this.railpackProvider,
    required this.railpackBuildCommand,
    required this.railpackRunCommand,
    required this.appPort,
  });

  final String name;
  final String type;
  final String gitUrl;
  final String primaryDomain;
  final String railpackRuntimeId;
  final String? railpackProvider;
  final String railpackBuildCommand;
  final String railpackRunCommand;
  final int appPort;
}

class CreateProjectView extends StatefulWidget {
  const CreateProjectView({super.key, this.onCancel, this.onCreate});

  final VoidCallback? onCancel;
  final ValueChanged<CreateProjectRequest>? onCreate;

  @override
  State<CreateProjectView> createState() => _CreateProjectViewState();
}

class _CreateProjectViewState extends State<CreateProjectView> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  String? _selectedRuntimeId;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) {
      return;
    }
    final selectedRuntime = railpackRuntimeForSelection(
      _selectedRuntimeId ?? railpackAutoDetectRuntimeId,
    );

    widget.onCreate?.call(
      CreateProjectRequest(
        name: _nameController.text.trim(),
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'Not configured',
        railpackRuntimeId: selectedRuntime.id,
        railpackProvider: selectedRuntime.provider,
        railpackBuildCommand: selectedRuntime.defaultBuildCommand,
        railpackRunCommand: selectedRuntime.defaultRunCommand,
        appPort: selectedRuntime.suggestedPort,
      ),
    );
  }

  String? _validateProjectName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Project name is required';
    }
    return null;
  }

  String? _validateRuntime(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Runtime is required';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AppFocusedFlowScaffold(
      key: const Key('create-project-focused-flow'),
      title: 'Create a project',
      subtitle:
          'Choose a name and runtime. You can connect code and add a domain later.',
      icon: Icons.add_box_outlined,
      actions: [
        if (widget.onCancel != null)
          OutlinedButton(
            key: const Key('create-project-cancel-button'),
            onPressed: widget.onCancel,
            child: const Text('Cancel'),
          ),
        FilledButton(
          key: const Key('create-project-submit-button'),
          onPressed: _submit,
          child: const Text('Create project'),
        ),
      ],
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppFormSection(
              children: [
                AppTextFormField(
                  fieldKey: const Key('create-project-name-field'),
                  controller: _nameController,
                  labelText: 'Project name',
                  hintText: 'My project',
                  validator: _validateProjectName,
                ),
                AppSelectFormField<String>(
                  fieldKey: const Key('create-project-runtime-field'),
                  labelText: 'Runtime',
                  helperText:
                      'Pick the main runtime so Deploy Dash starts with the right defaults.',
                  value: _selectedRuntimeId,
                  items: railpackRuntimeOptions
                      .where(
                        (runtime) => runtime.id != railpackAutoDetectRuntimeId,
                      )
                      .map(
                        (runtime) => DropdownMenuItem<String>(
                          value: runtime.id,
                          child: Text(runtime.label),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    setState(() {
                      _selectedRuntimeId = value;
                    });
                  },
                  validator: _validateRuntime,
                ),
              ],
            ),
            if (_selectedRuntimeId case final runtimeId?) ...[
              const SizedBox(height: 8),
              Text(
                railpackRuntimeForSelection(runtimeId).commandHelperText,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
