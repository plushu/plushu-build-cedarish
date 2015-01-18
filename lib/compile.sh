#!/bin/bash
set -eo pipefail; [[ -n "$PLUSHU_TRACE" ]] && set -x

## Locations
# these may be mounted volumes, or they may be copied in via some other
# mechanism before this script is run.
app_dir=/app
env_dir=/env
build_root=/src
cache_root=/cache
buildpack_root=/buildpacks

# Ensure all the source locations exist
mkdir -p $app_dir
mkdir -p $env_dir
mkdir -p $cache_root

# Ensure the destination location, and a location for profile scripts, exists
mkdir -p $build_root/.profile.d

# don't bother ensuring the buildpack location exists
# if buildpack_root is missing we have bigger problems to worry about

cd $build_root

## Set environment variables expected by buildpacks
export APP_DIR="$app_dir"
export HOME="$app_dir"
export REQUEST_ID=$(openssl rand -base64 32)
export STACK=cedar-14
export CURL_CONNECT_TIMEOUT=30

## Buildpack detection
buildpacks=($buildpack_root/*)
selected_buildpack=

if [[ -n "$BUILD_USE_BUILDPACK" ]]; then
	buildpack="$buildpack_root/$BUILD_USE_BUILDPACK"
	selected_buildpack="$buildpack"
	buildpack_name=$("$buildpack/bin/detect" "$build_root") &&
		selected_buildpack=$buildpack
else
  for buildpack in "${buildpacks[@]}"; do
  	buildpack_name=$("$buildpack/bin/detect" "$build_root") &&
  		selected_buildpack=$buildpack && break
  done
fi

if [[ -n "$selected_buildpack" ]]; then
	echo "       $buildpack_name app detected"
else
	echo "       Unable to select a buildpack"
	exit 1
fi

## Buildpack compile
"$selected_buildpack/bin/compile" "$build_root" "$cache_root" "$env_root"
"$selected_buildpack/bin/release" "$build_root"	> "$build_root/.release"

## Display process types
echo "-----> Discovering process types"
if [[ -f "$build_root/Procfile" ]]; then
	types=$(ruby -e "require 'yaml';puts YAML.load_file('$build_root/Procfile').keys().join(', ')")
	echo "       Procfile declares types -> $types"
fi
default_types=""
if [[ -s "$build_root/.release" ]]; then
	default_types=$(ruby -e "require 'yaml';puts (YAML.load_file('$build_root/.release')['default_process_types'] || {}).keys().join(', ')")
	[[ $default_types ]] && echo "       Default process types for $buildpack_name -> $default_types"
fi

## Generate start commands
cat > /exec <<EOF
#!/bin/bash
export HOME=$app_dir
cd $app_dir
for file in .profile.d/*.sh; do
	source \$file
done
hash -r
exec "\$@"
EOF

cat > /start <<EOF
#!/bin/bash
export HOME=$app_dir
cd $app_dir
for file in .profile.d/*.sh; do
	source \$file
done
hash -r
if [[ -f Procfile ]]; then
  exec bash -c "\$(ruby -e "require 'yaml';
  	puts YAML.load_file('Procfile')[ARGV[0]]" "\$1")"
else
	exec bash -c "\$(ruby -e "require 'yaml';
		puts (YAML.load_file('.release')['default_process_types']
			|| {})[ARGV[0]]" "\$1")"
fi
EOF

## Finalize build
chmod +x /exec
chmod +x /start
mkdir -p "$app_dir"
shopt -s dotglob nullglob
rm -rf "$app_dir/"* # ensure app_dir is clean
mv "$build_root/"* "$app_dir"

# Clean up
rm -rf /tmp/*
