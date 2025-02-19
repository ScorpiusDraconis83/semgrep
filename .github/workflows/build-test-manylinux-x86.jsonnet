// This workflow generates the manylinux-wheel for pypi.
local gha = import "libs/gha.libsonnet";
local actions = import "libs/actions.libsonnet";
local core_x86 = import "build-test-core-x86.jsonnet";

// ----------------------------------------------------------------------------
// The jobs
// ----------------------------------------------------------------------------

local artifact_name = core_x86.export.artifact_name;
local wheel_name = 'manylinux-x86-wheel';

local build_wheels_job = {
  'runs-on': 'ubuntu-latest',
  // pad: What is this sgrep-xxx image?
  container: 'returntocorp/sgrep-build:ubuntu-18.04',
  steps: [
    actions.checkout_with_submodules(),
    {
      run: 'apt-get update && apt install -y zip musl-tools software-properties-common python3-pip',
    },
    {
      run: |||
        add-apt-repository ppa:deadsnakes/ppa
        apt install -y python3.8
        update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.6 1
        update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.8 2
        update-alternatives --config python3
      |||
    },
    {
      uses: 'actions/download-artifact@v3',
      with: {
        name: artifact_name,
      },
    },
    {
      run: |||
        tar xf ocaml-build-artifacts.tgz
        cp ocaml-build-artifacts/bin/semgrep-core cli/src/semgrep/bin
        ./scripts/build-wheels.sh
      |||,
    },
    {
      uses: 'actions/upload-artifact@v3',
      with: {
        name: wheel_name,
        path: 'cli/dist.zip',
      },
    },
  ],
};

local test_wheels_job = {
  'runs-on': 'ubuntu-latest',
  // pad: what is that?
  container: 'quay.io/pypa/manylinux2014_x86_64',
  needs: [
    'build-wheels',
  ],
  steps: [
    {
      uses: 'actions/download-artifact@v1',
      with: {
        name: wheel_name,
      },
    },
    {
      run: 'unzip ./manylinux-x86-wheel/dist.zip',
    },
    // *.whl is fine here because we're building one wheel with the "any"
    // platform compatibility tag
    {
      name: 'install package',
      run: '/opt/python/cp38-cp38/bin/pip install dist/*.whl',
    },
    // TODO? could reuse build-test-osx-x86.test_semgrep_steps
    // only diff is PATH adjustments
    {
      name: 'test package',
      run: |||
        export PATH=/opt/python/cp38-cp38/bin:$PATH
        semgrep --version
      |||,
    },
    {
      name: 'e2e semgrep-core test',
      run: |||
        export PATH=/opt/python/cp38-cp38/bin:$PATH
        echo '1 == 1' | semgrep -l python -e '$X == $X' -
      |||,
    },
  ],
};

// ----------------------------------------------------------------------------
// The Workflow
// ----------------------------------------------------------------------------

{
  name: 'build-test-manylinux-x86',
  on: gha.on_dispatch_or_call,
  jobs: {
    'build-wheels': build_wheels_job,
    'test-wheels': test_wheels_job,
  },
}
