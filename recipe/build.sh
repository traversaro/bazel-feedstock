#!/bin/bash

set -euxo pipefail

if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="${LDFLAGS} -framework IOKit"
else
  export LDFLAGS="${LDFLAGS} -lpthread -labsl_synchronization"
fi

# Generate toolchain and set necessary environment variables
source gen-bazel-toolchain

if [[ "${target_platform}" == "osx-64" ]]; then
  export TARGET_CPU="darwin"
fi

# For debugging purposes, you can add
# --logging=6 --subcommands --verbose_failures
# This is though too much log output for Travis CI.
export LIBPROTOBUF_VERSION=$(conda list -p $PREFIX libprotobuf | grep -v '^#' | tr -s ' ' | cut -f 2 -d ' ')
export BAZEL_BUILD_OPTS="--crosstool_top=//bazel_toolchain:toolchain --define=PROTOBUF_INCLUDE_PATH=${PREFIX}/include --cpu=${TARGET_CPU}"
export EXTRA_BAZEL_ARGS="--host_javabase=@local_jdk//:jdk"
sed -ie "s:LIBPROTOBUF_VERSION:${LIBPROTOBUF_VERSION}:" WORKSPACE
sed -ie "s:\${INSTALL_NAME_TOOL}:${INSTALL_NAME_TOOL:-install_name_tool}:" src/BUILD
sed -ie "s:\${PREFIX}:${PREFIX}:" src/BUILD
sed -ie "s:\${BUILD_PREFIX}:${BUILD_PREFIX}:" third_party/grpc/BUILD
sed -ie "s:\${BUILD_PREFIX}:${BUILD_PREFIX}:" third_party/grpc-java/BUILD
sed -ie "s:\${BUILD_PREFIX}:${BUILD_PREFIX}:" third_party/systemlibs/protobuf.BUILD
sed -ie "s:\${BUILD_PREFIX}:${BUILD_PREFIX}:" third_party/ijar/BUILD
sed -ie "s:\${BUILD_PREFIX}:${BUILD_PREFIX}:" src/tools/singlejar/BUILD
sed -ie "s:TARGET_CPU:${TARGET_CPU}:" compile.sh
sed -ie "s:BUILD_CPU:${BUILD_CPU}:" compile.sh

./compile.sh

mkdir -p $PREFIX/bin/
cp ${RECIPE_DIR}/bazel-wrapper.sh $PREFIX/bin/bazel
chmod +x $PREFIX/bin/bazel
mv output/bazel $PREFIX/bin/bazel-real

# Explicitly unpack the contents of the bazel binary. This is normally done
# on demand during runtime. Then this is extracted to a random location and
# we cannot fix the RPATHs reliably.
#
# conda's binary relocation logic sadly doesn't work otherwise as
#  * The binaries are zipped into the main executable.
#  * Modifying the binaries changes their mtime and then bazel rejects them
#    as corrupted.
if [[ "${target_platform}" == linux-* ]]; then
  patchelf --set-rpath '$ORIGIN/../lib' $PREFIX/bin/bazel-real
fi
mkdir -p $PREFIX/share/bazel/install
mkdir -p install-archive
pushd install-archive
  unzip $PREFIX/bin/bazel-real
  export INSTALL_BASE_KEY=$(cat install_base_key)
popd
mv install-archive $PREFIX/share/bazel/install/${INSTALL_BASE_KEY}
chmod -R a+w $PREFIX/share/bazel/install/${INSTALL_BASE_KEY}
for executable in "build-runfiles" "daemonize" "linux-sandbox" "process-wrapper"; do
  if [[ "${target_platform}" == osx-* ]]; then
    ${INSTALL_NAME_TOOL} -rpath ${PREFIX}/lib '@loader_path/../../../../lib' $PREFIX/share/bazel/install/${INSTALL_BASE_KEY}/$executable
  else
    patchelf --set-rpath '$ORIGIN/../../../../lib' $PREFIX/share/bazel/install/${INSTALL_BASE_KEY}/$executable
  fi
done

# Also fix the RPATH for zipper. In the case we are cross-compiling, this is provided by the ijar package.
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "0" ]]; then
  if [[ "${target_platform}" == osx-* ]]; then
    ${INSTALL_NAME_TOOL} -rpath ${PREFIX}/lib '@loader_path/../../../../../../../../lib' $PREFIX/share/bazel/install/${INSTALL_BASE_KEY}/embedded_tools/tools/zip/zipper/zipper
  else
    patchelf --set-rpath '$ORIGIN/../../../../../../../../lib' $PREFIX/share/bazel/install/${INSTALL_BASE_KEY}/embedded_tools/tools/zip/zipper/zipper
  fi
fi

# Set timestamps to untampered, otherwise bazel will reject the modified files as corrupted.
find $PREFIX/share/bazel/install/${INSTALL_BASE_KEY} -type f | xargs touch -mt $(($(date '+%Y') + 10))10101010
chmod -R a-w $PREFIX/share/bazel/install/${INSTALL_BASE_KEY}
