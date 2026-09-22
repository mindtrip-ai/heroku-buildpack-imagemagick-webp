#!/bin/bash

# set -x
set -e

VERSION=${1:-22}
PLATFORM=linux/amd64
docker build --platform "$PLATFORM" -t heroku-buildpack-imagemagick-webp -f "Dockerfile.$VERSION" .
mkdir -p build

docker run --rm -t --platform "$PLATFORM" -v $PWD/build:/data heroku-buildpack-imagemagick-webp sh -c 'cp -f /usr/src/imagemagick/build/*.tar.gz /data/'
