#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v4.0.1 image: extend the official Joomla! v4.4.14 image
# -----------------------------------------------------------------------------
FROM joomla:4.4.14-php8.2-fpm-alpine@sha256:468450cd601e9327d67e1c33956e8d8787cad1488573eed3b60eb749bfe3ba31

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v4.4.14 + Component Builder v4.0.1"
LABEL org.opencontainers.image.version="4.0.1"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:4.4.14-php8.2-fpm-alpine"
LABEL org.opencontainers.image.base.digest="sha256:468450cd601e9327d67e1c33956e8d8787cad1488573eed3b60eb749bfe3ba31"

# -----------------------------------------------------------------------------
# JCB metadata (required at build-time)
# -----------------------------------------------------------------------------
ENV JCB_VERSION 4.0.1
ENV JCB_SHA512 3fdaac224c16cb3be6a5d702ee2d3d1a8491915ff2520d36bcd15ababd387f48c72ccfa3b0db1c36bcdca75477e018bd3b1db68fd6ea06054e248733c2b97478
ENV JCB_PACKAGE https://github.com/joomengine/pkg-component-builder/archive/refs/tags/v4.0.1.zip
ENV JCB_INSTALL_DIR /usr/src/joomengine

# -----------------------------------------------------------------------------
# Download & verify JCB package (immutable, pinned, hash-verified)
# -----------------------------------------------------------------------------
RUN set -eux; \
	mkdir -p "$JCB_INSTALL_DIR"; \
	curl -fSL "$JCB_PACKAGE" -o "$JCB_INSTALL_DIR/jcb.zip"; \
	echo "$JCB_SHA512  $JCB_INSTALL_DIR/jcb.zip" | sha512sum -c -; \
	chown -R www-data:www-data "$JCB_INSTALL_DIR"

# -----------------------------------------------------------------------------
# JCB entrypoint
# -----------------------------------------------------------------------------
COPY docker-entrypoint.sh /entrypoint.sh
RUN set -eux; \
	chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
