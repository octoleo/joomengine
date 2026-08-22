#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v4.0.2 image: extend the official Joomla! v4.4.14 image
# -----------------------------------------------------------------------------
FROM joomla:4.4.14-php8.1-apache@sha256:82f47d466118b7a4b82b55d2fad681a903061d9a34469cef37fff961e20f4550

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v4.4.14 + Component Builder v4.0.2"
LABEL org.opencontainers.image.version="4.0.2"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:4.4.14-php8.1-apache"
LABEL org.opencontainers.image.base.digest="sha256:82f47d466118b7a4b82b55d2fad681a903061d9a34469cef37fff961e20f4550"

# -----------------------------------------------------------------------------
# JCB metadata (required at build-time)
# -----------------------------------------------------------------------------
ENV JCB_VERSION 4.0.2
ENV JCB_SHA512 71827b08ee6b634848373e5470b25251dd2520603ec788d43910bb8172344fb086dfd9e6f1c6b145643fd00b71ce84661bd5f32e89281749e64c02a2eb1f5a0c
ENV JCB_PACKAGE https://github.com/joomengine/pkg-component-builder/archive/refs/tags/v4.0.2.zip
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
CMD ["apache2-foreground"]
