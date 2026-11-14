#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v6.2.1-alpha2 image: extend the official Joomla! v6.2.0 image
# -----------------------------------------------------------------------------
FROM joomla:6.2.0-php8.3-fpm-alpine@sha256:8e6e99b5b9ea138feeef162a53bb39c8f4511bcefe77044d3bec03e007a0b6c8

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v6.2.0 + Component Builder v6.2.1-alpha2"
LABEL org.opencontainers.image.version="6.2.1-alpha2"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:6.2.0-php8.3-fpm-alpine"
LABEL org.opencontainers.image.base.digest="sha256:8e6e99b5b9ea138feeef162a53bb39c8f4511bcefe77044d3bec03e007a0b6c8"

# -----------------------------------------------------------------------------
# JCB metadata (required at build-time)
# -----------------------------------------------------------------------------
ENV JCB_VERSION 6.2.1-alpha2
ENV JCB_SHA512 633565921200bced8248cad75cb7b1b06c60fd3546bf6b866ffab81623753014f81dff1776cec9adccc9beb9d9c188ec724d2089e538ce460090ac4280dc7cae
ENV JCB_PACKAGE https://github.com/joomengine/pkg-component-builder/archive/refs/tags/v6.2.1-alpha2.zip
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
