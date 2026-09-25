#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v5.0.2 image: extend the official Joomla! v5.4.8 image
# -----------------------------------------------------------------------------
FROM joomla:5.4.8-php8.3-fpm-alpine@sha256:88932a6301dbf22b562226c91ad9c0e931c5f3c7b8c1f4fc4b0040981f82b0e2

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v5.4.8 + Component Builder v5.0.2"
LABEL org.opencontainers.image.version="5.0.2"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:5.4.8-php8.3-fpm-alpine"
LABEL org.opencontainers.image.base.digest="sha256:88932a6301dbf22b562226c91ad9c0e931c5f3c7b8c1f4fc4b0040981f82b0e2"

# -----------------------------------------------------------------------------
# JCB metadata (required at build-time)
# -----------------------------------------------------------------------------
ENV JCB_VERSION 5.0.2
ENV JCB_SHA512 28449716b4c744e4310542d519e53419ac4a7f4caaa2caa3c15540a78a4d0890996b50213c27cc54b7a4bc12a143be08ee9ce4a362c62e5c0031ba3a794f7b8e
ENV JCB_PACKAGE https://github.com/joomengine/pkg-component-builder/archive/refs/tags/v5.0.2.zip
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
