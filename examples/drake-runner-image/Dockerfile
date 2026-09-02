FROM ubuntu:24.04@sha256:1e0a86e57d247923571b75e0aaf48a1449cf8c543d51fb3e07a4a7d7bfa79316

USER root

ARG DEBIAN_FRONTEND=noninteractive
ARG DRAKE_COMMIT=c72e0affe

# Install Drake's complete, commit-matched Ubuntu 24.04 developer environment.
# The source archive is only needed to run Drake's authoritative installer and
# is removed in the same layer, so it is not retained in the final image.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    tar \
    wget \
  && mkdir /tmp/drake \
  && wget -qO /tmp/drake.tar.gz \
    "https://github.com/RobotLocomotion/drake/archive/${DRAKE_COMMIT}.tar.gz" \
  && tar -xf /tmp/drake.tar.gz -C /tmp/drake --strip-components=1 \
  && /tmp/drake/setup/install_prereqs --developer -y \
  && rm -rf /tmp/drake /tmp/drake.tar.gz \
  && rm -rf /var/lib/apt/lists/*

# Make f951 visible on Bazel's restricted action PATH because SPRAL stages the
# GFortran driver under the generic executable name "compiler".
RUN ln -sfn "$(gfortran -print-prog-name=f951)" /usr/bin/f951

# rules_cc resolves /usr/bin/clang-20 to /usr/lib/llvm-20/bin/clang while
# generating the toolchain, so the wrapper must live at that resolved path.
# Normalize only its invalid absolute-linker argument before invoking the
# packaged compiler saved alongside it.
RUN mv /usr/lib/llvm-20/bin/clang /usr/lib/llvm-20/bin/clang.real
COPY --chmod=0755 clang-20-wrapper /usr/lib/llvm-20/bin/clang

# Fail the image build if its advertised toolchain is incomplete or the image
# was accidentally built for a non-x86-64 platform.
RUN test "$(uname -m)" = x86_64 \
  && test -f /usr/include/x86_64-linux-gnu/python3.12/pyconfig.h \
  && python3 -c 'import yaml; print(yaml.__version__)' \
  && cmake --version \
  && gcc --version \
  && gfortran --version \
  && env PATH=/usr/bin:/bin f951 --version \
  && printf 'program smoke\nend program smoke\n' > /tmp/smoke.f90 \
  && gfortran /tmp/smoke.f90 -o /tmp/smoke-fortran \
  && /tmp/smoke-fortran \
  && rm /tmp/smoke.f90 /tmp/smoke-fortran \
  && clang-20 --version \
  && ld.lld --version \
  && printf 'int main() { return 0; }\n' > /tmp/smoke.cc \
  && clang-20 /tmp/smoke.cc -fuse-ld=/usr/bin/ld.lld -o /tmp/smoke-clang \
  && /tmp/smoke-clang \
  && /usr/lib/llvm-20/bin/clang /tmp/smoke.cc -fuse-ld=/usr/bin/ld.lld -o /tmp/smoke-clang-resolved \
  && /tmp/smoke-clang-resolved \
  && printf '%s\n' /tmp/smoke.cc -fuse-ld=/usr/bin/ld.lld -o /tmp/smoke-clang-response > /tmp/smoke.params \
  && clang-20 @/tmp/smoke.params \
  && /tmp/smoke-clang-response \
  && rm /tmp/smoke.cc /tmp/smoke.params /tmp/smoke-clang /tmp/smoke-clang-resolved /tmp/smoke-clang-response
