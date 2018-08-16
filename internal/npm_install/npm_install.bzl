# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Install npm packages

Rules to install NodeJS dependencies during WORKSPACE evaluation.
This happens before the first build or test runs, allowing you to use Bazel
as the package manager.

See discussion in the README.
"""

load("//internal/node:node_labels.bzl", "get_node_label", "get_npm_label", "get_yarn_label")
load("//internal/common:os_name.bzl", "os_name")

def _create_build_file(repository_ctx):
#   if repository_ctx.attr.node_modules_filegroup:
#     repository_ctx.file("BUILD", """
# package(default_visibility = ["//visibility:public"])
# """ + repository_ctx.attr.node_modules_filegroup)
#   else:
#     repository_ctx.file("BUILD", """
# package(default_visibility = ["//visibility:public"])
# filegroup(
#     name = "node_modules",
#     srcs = glob(["node_modules/**/*"],
#         # Exclude directories that commonly contain filenames which are
#         # illegal bazel labels
#         exclude = [
#             # e.g. node_modules/adm-zip/test/assets/attributes_test/New folder/hidden.txt
#             "node_modules/**/test/**",
#             # e.g. node_modules/xpath/docs/function resolvers.md
#             "node_modules/**/docs/**",
#             # e.g. node_modules/puppeteer/.local-chromium/mac-536395/chrome-mac/Chromium.app/Contents/Versions/66.0.3347.0/Chromium Framework.framework/Chromium Framework
#             "node_modules/**/.*/**"
#         ],
#     ) + glob(["node_modules/.bin/*"]),
# )
# """)
  node = repository_ctx.path(get_node_label(repository_ctx))
  # Grab the @yarnpkg/lockfile dependency
  repository_ctx.download_and_extract(
      url = "https://registry.yarnpkg.com/@yarnpkg/lockfile/-/lockfile-1.0.0.tgz",
      output = "internal/node_modules/@yarnpkg/lockfile",
      sha256 = "472add7ad141c75811f93dca421e2b7456045504afacec814b0565f092156250",
      stripPrefix = "package",
  )
  repository_ctx.template("internal/parse_yarn_lock.js",
      repository_ctx.path(repository_ctx.attr._parse_yarn_lock_js), {})
  result = repository_ctx.execute([node, "internal/parse_yarn_lock.js"])
  if result.return_code:
    fail("node failed: \nSTDOUT:\n%s\nSTDERR:\n%s" % (result.stdout, result.stderr))

def _add_data_dependencies(repository_ctx):
  """Add data dependencies to the repository."""
  for f in repository_ctx.attr.data:
    to = []
    if f.package:
      to += [f.package]
    to += [f.name]
    repository_ctx.symlink(f, repository_ctx.path("/".join(to)))

def _npm_install_impl(repository_ctx):
  """Core implementation of npm_install."""

  _create_build_file(repository_ctx)

  is_windows = os_name(repository_ctx).find("windows") != -1
  node = get_node_label(repository_ctx)
  npm = get_npm_label(repository_ctx)
  npm_args = ["install"]

  if repository_ctx.attr.prod_only:
    npm_args.append("--production")

  # The entry points for npm install for osx/linux and windows
  if not is_windows:
    repository_ctx.file("npm", content="""#!/bin/bash
(cd "{root}"; "{npm}" {npm_args})
""".format(
    root = repository_ctx.path(""),
    npm = repository_ctx.path(npm),
    npm_args = " ".join(npm_args)),
    executable = True)
  else:
    repository_ctx.file("npm.cmd", content="""@echo off
cd "{root}" && "{npm}" {npm_args}
""".format(
    root = repository_ctx.path(""),
    npm = repository_ctx.path(npm),
    npm_args = " ".join(npm_args)),
    executable = True)

  # Put our package descriptors in the right place.
  repository_ctx.symlink(
      repository_ctx.attr.package_json,
      repository_ctx.path("package.json"))
  if repository_ctx.attr.package_lock_json:
      repository_ctx.symlink(
          repository_ctx.attr.package_lock_json,
          repository_ctx.path("package-lock.json"))

  _add_data_dependencies(repository_ctx)

  # To see the output, pass: quiet=False
  result = repository_ctx.execute(
    [repository_ctx.path("npm.cmd" if is_windows else "npm")])

  if not repository_ctx.attr.package_lock_json:
    print("\n***********WARNING***********\n%s: npm_install will require a package_lock_json attribute in future versions\n*****************************" % repository_ctx.name)

  if result.return_code:
    fail("npm_install failed: %s (%s)" % (result.stdout, result.stderr))

  remove_npm_absolute_paths = Label("@build_bazel_rules_nodejs_npm_install_deps//:node_modules/removeNPMAbsolutePaths/bin/removeNPMAbsolutePaths")

  # removeNPMAbsolutePaths is run on node_modules after npm install as the package.json files
  # generated by npm are non-deterministic. They contain absolute install paths and other private
  # information fields starting with "_". removeNPMAbsolutePaths removes all fields starting with "_".
  result = repository_ctx.execute(
    [repository_ctx.path(node), repository_ctx.path(remove_npm_absolute_paths), repository_ctx.path("")])

  if result.return_code:
    fail("remove_npm_absolute_paths failed: %s (%s)" % (result.stdout, result.stderr))

npm_install = repository_rule(
    attrs = {
        "package_json": attr.label(
            allow_files = True,
            mandatory = True,
            single_file = True,
        ),
        "package_lock_json": attr.label(
            allow_files = True,
            single_file = True,
        ),
        "prod_only": attr.bool(
            default = False,
            doc = "Don't install devDependencies",
        ),
        "data": attr.label_list(),
        "node_modules_filegroup": attr.string(
            doc = """Experimental attribute that can be used to work-around
            a bazel performance issue if the default node_modules filegroup
            has too many files in it. Use it to define the node_modules
            filegroup used by this rule such as
            "filegroup(name = "node_modules", srcs = glob([...]))". See
            https://github.com/bazelbuild/bazel/issues/5153."""),
    },
    implementation = _npm_install_impl,
)
"""Runs npm install during workspace setup.
"""

def _yarn_install_impl(repository_ctx):
  """Core implementation of yarn_install."""

  # Put our package descriptors in the right place.
  repository_ctx.symlink(
      repository_ctx.attr.package_json,
      repository_ctx.path("package.json"))
  if repository_ctx.attr.yarn_lock:
      repository_ctx.symlink(
          repository_ctx.attr.yarn_lock,
          repository_ctx.path("yarn.lock"))

  _add_data_dependencies(repository_ctx)

  yarn = get_yarn_label(repository_ctx)

  # A local cache is used as multiple yarn rules cannot run simultaneously using a shared
  # cache and a shared cache is non-hermetic.
  # To see the output, pass: quiet=False
  args = [
    repository_ctx.path(yarn),
    "--cache-folder",
    repository_ctx.path("_yarn_cache"),
    "--cwd",
    repository_ctx.path(""),
  ]

  if repository_ctx.attr.prod_only:
    args.append("--prod")

  result = repository_ctx.execute(args)

  if result.return_code:
    fail("yarn_install failed: %s (%s)" % (result.stdout, result.stderr))

  _create_build_file(repository_ctx)

yarn_install = repository_rule(
    attrs = {
        "package_json": attr.label(
            allow_files = True,
            mandatory = True,
            single_file = True,
        ),
        "yarn_lock": attr.label(
            allow_files = True,
            mandatory = True,
            single_file = True,
        ),
        "prod_only": attr.bool(
            default = False,
            doc = "Don't install devDependencies",
        ),
        "data": attr.label_list(),
        "node_modules_filegroup": attr.string(
            doc = """Experimental attribute that can be used to work-around
            a bazel performance issue if the default node_modules filegroup
            has too many files in it. Use it to define the node_modules
            filegroup used by this rule such as
            "filegroup(name = "node_modules", srcs = glob([...]))". See
            https://github.com/bazelbuild/bazel/issues/5153."""),
        "_parse_yarn_lock_js": attr.label(
            allow_single_file = True,
            default = Label("//internal/npm_install:parse_yarn_lock.js"),
        ),
    },
    implementation = _yarn_install_impl,
)
"""Runs yarn install during workspace setup.
"""
