"""Macros for running acceptance tests."""

load("@rules_pkg//pkg:zip.bzl", "pkg_zip")
load("@io_bazel_rules_go//go:def.bzl", "go_test")

# acceptance_test_suite defines several targets that are useful with buildpacks acceptance tests.
# It defines a test target for each version, a test suite that runs all of the versioned targets,
# a cloudbuild build configuration, and tarball for submitting to cloudbuild. See below for more
# specifics on each of the targets.
#
# Given a name of 'gae_test' and versions value of [1.13, 1.14], it defines the following:
# * 1.13_gae_test: A test target with a version of 1.13.
# * 1.14_gae_test: A test target with a version of 1.14.
# * gae_test: A test suite target that aliases to [1.13_gae_test, 1.14_gae_test]. Useful for running
#   all versions of the tests.
# * gae_test_cloudbuild.yaml: A cloudbuild config which contains a step for running the tests
#   against 1.13 and a step for running against 1.14.
# * gae_test_cloudbuild.zip: A zip which can be used with 'gae_test_cloudbuild.yaml' to
#   submit a cloudbuild.
#
# To submit a cloudbuild with the go builder:
#   blaze build //third_party/gcp_buildpacks/builders/go/acceptance:gae_test_cloudbuild.zip
#   blaze build //third_party/gcp_buildpacks/builders/go/acceptance:gae_test_cloudbuild.yaml
#   gcloud builds submit \
#      blaze-bin/third_party/gcp_buildpacks/builders/go/acceptance/gae_test_cloudbuild.zip \
#      --config blaze-genfiles/third_party/gcp_buildpacks/builders/go/acceptance/gae_test_cloudbuild.yaml

def acceptance_test_suite(
        name,
        srcs,
        testdata,
        builder = None,
        structure_test_config = ":config.yaml",
        versions = {},
        runtime_to_builder_map = None,
        args = None,
        deps = None,
        argsmap = None,
        **kwargs):
    """Macro to define an acceptance test.

    Args:
      name: the name of the test
      srcs: the test source files
      testdata: a build target for a directory containing sample test applications
      builder: a build target for a builder.tar to test
      structure_test_config: a build target for the structured container test's config file
      versions: a list of GOOGLE_RUNTIME_VERSIONS to test, these correspond to language versions
      args: additional arguments to be passed to the test binary beyond ones corresponding to the arguments to this function
      deps: additional test dependencies beyond the acceptance package
      argsmap: version specific arguments map where the key is the version and the value is a list of flags that will be passed to the acceptance test framework
      **kwargs: this argument captures all additional arguments and forwards them to the generated go_test rule
    """
    deps = _build_deps(deps)
    _build_tests(name, srcs, args, testdata, builder, structure_test_config, deps, versions, runtime_to_builder_map, argsmap, **kwargs)
    _cloudbuild_targets(name, srcs, structure_test_config, builder, args, deps, versions, argsmap, testdata)

def _build_tests(name, srcs, args, testdata, builder, structure_test_config, deps, versions, runtime_to_builder_map, argsmap, **kwargs):
    # if there are no versions passed in then create a go_test(...) rule directly without changing
    # the name of the test
    if versions == {}:
        test_args = _build_args(args, name, testdata, builder, structure_test_config)
        data = _build_data(structure_test_config, builder, testdata)
        _new_go_test_for_single_version(name, srcs, test_args, data, deps, **kwargs)
    else:
        _new_go_test_for_versions(versions, name, srcs, args, testdata, builder, structure_test_config, runtime_to_builder_map, deps, argsmap, **kwargs)

def _new_go_test_for_versions(versions, name, srcs, args, testdata, builder, structure_test_config, runtime_to_builder_map, deps, argsmap, **kwargs):
    tests = []
    if type(versions) == type({}):
        for _n, v in versions.items():
            selected_builder = _select_builder(builder, runtime_to_builder_map, _n)
            test_args = _build_args(args, name, testdata, selected_builder, structure_test_config)
            data = _build_data(structure_test_config, selected_builder, testdata)
            ver_name = v + "_" + name
            tests.append(ver_name)
            ver_args = list(test_args)
            ver_args.append("-runtime-version=" + v)

            if argsmap != None and argsmap.get(v) != None:
                for ak, av in argsmap[v].items():
                    ver_args.append(ak + "=" + av)

            _new_go_test(ver_name, srcs, ver_args, data, deps, **kwargs)

    # Each of the go_test(...) rules generated by _new_go_test have a name that is hard for
    # developers to reference, for example, '//acceptance:gcp_test_3.1.416'. To make this
    # easy to use, generate a test suite with the name of the original build target, so
    # developers can reference simply '//acceptance:gcp_test'.
    native.test_suite(
        name = name,
        tests = tests,
    )
    if len(tests) > 0:
        _new_bin_filegroup_alias(name, tests[0])

def _select_builder(builder, runtime_to_builder_map, runtime):
    selected_builder = builder
    if runtime_to_builder_map != None and runtime in runtime_to_builder_map:
        selected_builder = runtime_to_builder_map[runtime]
    return selected_builder

def _new_go_test_for_single_version(name, srcs, args, data, deps, **kwargs):
    _new_go_test(name, srcs, args, data, deps, **kwargs)
    _new_bin_filegroup_alias(name, name)

def _new_go_test(name, srcs, args, data, deps, **kwargs):
    go_test(
        name = name,
        size = "enormous",
        srcs = srcs,
        args = args,
        data = data,
        tags = [
            "local",
        ],
        gc_linkopts = [],
        deps = deps,
        **kwargs
    )

def _new_bin_filegroup_alias(name, test_name):
    # The test binaries generated in this file have names such as '1.13_gae_test'. For external
    # consumers who wish to invoke the test binary directly, the following filegroup gives them
    # a static name that they can reference such as 'gae_test_bin'.
    native.filegroup(
        name = name + "_bin",
        srcs = [":" + test_name],
        testonly = 1,
    )

def _build_args(args, name, testdata, builder, structure_test_config):
    short_name = _remove_suffix(name, "_test")
    builder_name = _extract_builder_name(builder)

    if args == None:
        args = []
    else:
        # make a copy of the args list to prevent mutating the passed in value
        args = list(args)
    args.append("-test-data=$(location " + testdata + ")")
    args.append("-structure-test-config=$(location " + structure_test_config + ")")
    args.append("-builder-source=$(location " + builder + ")")
    args.append("-builder-prefix=" + builder_name + "-" + short_name + "-acceptance-test-")
    args.append("-runtime-name=" + builder_name)
    return args

def _build_data(structure_test_config, builder, testdata):
    return [
        structure_test_config,
        builder,
        testdata,
    ]

def _extract_builder_name(builder):
    # A builder target is a full google3 path, the name of the builder, and then :builder.tar, the following
    # extracts the name of the builder.
    builder_name = _remove_suffix(builder, ":builder.tar")
    builder_name = builder_name[builder_name.rindex("/") + 1:]
    return builder_name

def _build_deps(deps):
    if deps == None:
        deps = []
    else:
        # make a copy of the list to prevent mutating a shared 'deps' value declared in a BUILD file
        deps = list(deps)
    deps.append("//internal/acceptance")
    return deps

# Once bazel supports python 3.9, this function can be replaced with `value.removesuffix(suffix)`:
def _remove_suffix(value, suffix):
    if value.endswith(suffix):
        value = value[:-len(suffix)]
    return value

def is_bazel_build(testdata):
    return not testdata.startswith("//third_party/gcp_buildpacks")

# _cloudbuild_targets builds two rules that can be used to run the acceptance tests in gcloud.
def _cloudbuild_targets(name, srcs, structure_test_config, builder, args, deps, versions, argsmap, testdata):
    bin_name = _build_cloudbuild_test_binary(name, srcs, deps)

    # this hack is to conditionally prevent testdata from being zipped in bazel, as
    # _build_testdata_target makes use of Fileset which is not available in bazel.
    if not is_bazel_build(testdata):
        _build_cloudbuild_zip(name, bin_name, structure_test_config, builder, testdata)
    _build_cloudbuild_config_target(name, bin_name, builder, args, versions, argsmap, testdata)
    _build_per_version_cloudbuild_config_targets(name, bin_name, builder, args, versions, argsmap, testdata)

def _build_cloudbuild_zip(name, bin_name, structure_test_config, builder, testdata):
    if "java" in testdata:
        testdata_fileset_name = testdata
    else:
        testdata_fileset_name = _build_testdata_target(name, testdata)
    pkg_zip(
        name = name + "_cloudbuild",
        srcs = [
            bin_name,
            builder,
            testdata_fileset_name,
            structure_test_config,
        ],
        testonly = 1,
    )

def _build_cloudbuild_test_binary(name, srcs, deps):
    bin_name = name + "_cloudbuild_bin"
    _new_go_test(bin_name, srcs, None, None, deps)
    return bin_name

# _build_testdata_target creates a Fileset target for the given testdata label. The reason to do
# this is our testdata is accessed via exports_files(...) which copies the testdata into writeable
# folders. The acceptance test suite relies on the the folders being writeable. We assume the
# existence of a filegroup with the name "[testdata_label]_files" to bring in the required files.
def _build_testdata_target(name, testdata):
    testdata_pkg, testdata_label = testdata.split(":")
    fileset_name = name + "_" + testdata_label
    testdata_filegroup = testdata_label + "_files"
    native.Fileset(
        name = fileset_name,
        out = name + "_generated/" + testdata_label,
        entries = [
            native.FilesetEntry(
                srcdir = testdata_pkg + ":BUILD",
                files = [testdata_filegroup],
                strip_prefix = testdata_label,
            ),
        ],
    )
    return fileset_name

def _build_per_version_cloudbuild_config_targets(name, bin_name, builder, args, versions, argsmap, testdata):
    if versions != {} and type(versions) == type({}):
        for n, version in versions.items():
            version_name = name + "_" + n
            cloudbuild_config = _build_cloudbuild_config(name, bin_name, builder, args, {n: version}, argsmap, testdata)
            native.genrule(
                name = version_name + "_cloudbuild_config",
                outs = [version_name + "_cloudbuild.yaml"],
                cmd = "echo '" + cloudbuild_config + "' >> $@",
            )

def _build_cloudbuild_config_target(name, bin_name, builder, args, versions, argsmap, testdata):
    cloudbuild_config = _build_cloudbuild_config(name, bin_name, builder, args, versions, argsmap, testdata)
    native.genrule(
        name = name + "_cloudbuild_config",
        outs = [name + "_cloudbuild.yaml"],
        cmd = "echo '" + cloudbuild_config + "' >> $@",
    )

# "LOOSE" substitution option is enabled so that unused variables can be defined like
# '_RUNTIME_LANGUAGE'. This which will be useful to consumers who wish to insert their own
# substitutions and want to reference common properties.
#
# To use a different builder than the 'builder.tar' that was passed into acceptance_test_suite,
# define the _BUILDER_IMAGE substitution. For example, replace the empty string with
#   gcr.io/gae-runtimes/buildpacks/{_RUNTIME_LANGUAGE}/builder:latest
_buildconfig_template = """options:
  machineType: E2_HIGHCPU_8
  dynamic_substitutions: true
  substitution_option: 'ALLOW_LOOSE'
substitutions:
  _PULL_IMAGES: \"true\"
  _BUILDER_IMAGE: \"\"
  _RUNTIME_LANGUAGE: ${runtime_language}
timeout: 3600s
steps:
- id: fix-permissions
  name: gcr.io/gae-runtimes/utilities/pack:latest
  entrypoint: /bin/bash
  args:
  - -c
  - chmod -R 755 *
"""

def _build_cloudbuild_config(name, bin_name, builder, args, versions, argsmap, testdata):
    builder_name = _extract_builder_name(builder)
    result = _format_cloudbuild_config(builder_name)
    steps = _build_cloudbuild_steps(name, bin_name, args, versions, argsmap, testdata)
    for s in steps:
        s = indent(s, 2)
        result += "- " + s + "\n"
    return result

def _format_cloudbuild_config(runtime_language):
    result = _buildconfig_template
    result = result.replace("${runtime_language}", runtime_language)
    return result

def indent(value, n, ch = " "):
    padding = n * ch
    lines = value.splitlines(True)
    return padding.join(lines)

def _build_cloudbuild_steps(name, bin_name, args, versions, argsmap, testdata):
    testdata_label = testdata[testdata.rfind(":") + 1:]

    # if there were no versions passed in then create a list with a single None value so the
    # below loop will still have a single iteration and pass a None value for version to _build_step
    if versions == {}:
        versions = {"None": None}

    steps = []
    if type(versions) == type({}):
        for _n, ver in versions.items():
            if args == None:
                ver_args = []
            else:
                ver_args = list(args)
            if argsmap != None and argsmap.get(ver) != None:
                for key, val in argsmap[ver].items():
                    ver_args.append(key + "=" + val)
            step_config = _build_step(name, bin_name, ver, ver_args, testdata_label)
            steps.append(step_config)
    return steps

# By default, _BUILDER_IMAGE is defined as the empty string. The acceptance test framework will
# use the flag -builder-source when -builder-image is empty. When -builder-image has a value then
# it takes precedence over -builder-source.
_step_template = """entrypoint: /bin/bash
id: ${test_name}
name: gcr.io/gae-runtimes/utilities/pack:latest
waitFor: ['fix-permissions']
args:
- -c
- >
  ./${bin_name} \\
    -cloudbuild \\
    -pull-images=$${_PULL_IMAGES} \\
    -test-data=${testdata} \\
    -builder-source=builder.tar \\
    -builder-image=$${_BUILDER_IMAGE} \\
    -runtime-name=$${_RUNTIME_LANGUAGE} \\
    -structure-test-config=config.yaml"""

def _build_step(name, bin_name, version, args, testdata_label):
    result = _step_template
    result = result.replace("${bin_name}", bin_name)
    if version != None:
        name = name + "-" + version
    result = result.replace("${test_name}", name)
    result = result.replace("${testdata}", testdata_label)
    if args == None:
        args = []
    if version != None:
        args.append("-runtime-version=" + version)
    for a in args:
        result += " \\\n    " + a
    return result

_default_cloudbuild_bin_targets = ["flex_test_cloudbuild_bin", "gae_test_cloudbuild_bin", "gcf_test_cloudbuild_bin", "gcp_test_cloudbuild_bin"]

def _build_argo_source_testdata_fileset_target(name, testdata):
    fileset_name = name + "_testdata"
    testdata_pkg, testdata_label = testdata.split(":")
    native.Fileset(
        name = fileset_name,
        out = "testdata",
        entries = [
            native.FilesetEntry(
                srcdir = testdata_pkg,
                files = [testdata_label],
                strip_prefix = "",
            ),
        ],
    )
    return fileset_name

def acceptance_test_argo_source(name, testdata, srcs = [], structure_test_config = ":config.yaml"):
    # this hack is to conditionally prevent testdata from being zipped in bazel, as
    # _build_testdata_target makes use of Fileset which is not available in bazel.
    if is_bazel_build(testdata):
        return

    testdata_fileset_target = _build_argo_source_testdata_fileset_target(name, testdata)
    pkg_zip(
        name = name,
        srcs = srcs + _default_cloudbuild_bin_targets + [
            testdata_fileset_target,
            structure_test_config,
        ],
        testonly = 1,
    )

def create_acceptance_versions_dict_file(name, file, flex_runtime_versions, gae_runtime_versions, gcf_runtime_versions, gcp_runtime_versions, **kwargs):
    """Export a file that contains a dictionary of product to a list of strings, each of which can be parsed as {{runtime id}}:{{runtime semver version}}

    Takes input dictionaries for each of the products for a single language

    Creates an output file with the following structure:
    ========
    {
        flex: [go118:1.18.10, go119:1.19.13, go120:1.20.10, go121:1.21.3],
        gae: [go111:1.11.13, go112:1.12.17, go113:1.13.15, go114:1.14.15, go115:1.15.15, go116:1.16.15, go118:1.18.10, go119:1.19.13, go120:1.20.10, go121:1.21.3],
        gcf: [go113:1.13.15, go116:1.16.15, go118:1.18.10, go119:1.19.13, go120:1.20.10, go121:1.21.3],
        gcp: [go118:1.18.10, go119:1.19.13, go120:1.20.10, go121:1.21.3, go111:1.11.13, go112:1.12.17, go113:1.13.15, go114:1.14.15, go115:1.15.15, go116:1.16.15],
    }
    ========

    Args:
        name: name of the target to create
        file: the output file name
        multiline with additional indentation.
        flex_runtime_versions: bzl/python map of flex runtimes to exact runtime semvers for the
                                given runtime
        gae_runtime_versions: bzl/python map of gae runtimes to exact runtime semvers for the
                                given runtime
        gcf_runtime_versions: bzl/python map of gcf runtimes to exact runtime semvers for the
                                given runtime
        gcp_runtime_versions: bzl/python map of gcp runtimes to exact runtime semvers for the
                                given runtime
        **kwargs: passed through to the native.genrule.
    """
    d = dict()
    d["flex"] = [k + ":" + v for k, v in flex_runtime_versions.items()]
    d["gae"] = [k + ":" + v for k, v in gae_runtime_versions.items()]
    d["gcf"] = [k + ":" + v for k, v in gcf_runtime_versions.items()]
    d["gcp"] = [k + ":" + v for k, v in gcp_runtime_versions.items()]
    native.genrule(
        name = name,
        outs = [file],
        cmd = ("echo " + str(d) + " > $@"),
        visibility = ["//visibility:public"],
        **kwargs
    )
