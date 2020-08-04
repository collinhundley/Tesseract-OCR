#!/bin/bash -x

FILES="leptonica-1.80.0 giflib-5.2.1 jpeg-9d libpng-1.6.37 libtiff-4.1.0 openjpeg-2.3.1 little-cms2-2.11 webp-1.1.0 tesseract-4.1.1 curl-7.71.1"
OS="mojave"

rm -rf lib include

rm -rf homebrew-dl && mkdir -p homebrew-dl
for file in $FILES; do
	curl -s -L  https://homebrew.bintray.com/bottles/${file}.${OS}.bottle.tar.gz | tar xfC  - homebrew-dl
done

pwd=`pwd`
for dir in homebrew-dl/*/*; do
  ( cd $dir
	find lib -name "*.a" | cpio -pd --insecure ${pwd}
	find include  -name "*.h" | cpio --insecure -pd ${pwd}
  )
done

#rm -rf homebrew-dl
