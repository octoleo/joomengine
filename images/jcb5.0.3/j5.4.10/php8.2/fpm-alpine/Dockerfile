#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v5.0.3 image: extend the official Joomla! v5.4.10 image
# -----------------------------------------------------------------------------
FROM joomla:5.4.10-php8.2-fpm-alpine@sha256:0d6191c346ff46def39607b5203bdb6122b4f0315eee17247969a64657f9f962

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v5.4.10 + Component Builder v5.0.3"
LABEL org.opencontainers.image.version="5.0.3"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:5.4.10-php8.2-fpm-alpine"
LABEL org.opencontainers.image.base.digest="sha256:0d6191c346ff46def39607b5203bdb6122b4f0315eee17247969a64657f9f962"

# -----------------------------------------------------------------------------
# JCB metadata (required at build-time)
# -----------------------------------------------------------------------------
ENV JCB_VERSION 5.0.3
ENV JCB_SHA512 d92fb41e0b084ff467ea9200428076730ada684b19d74bfd59bf11cfc35a6efb5208a2ceedd23377bcdd16f193853f263fdc074d5414f630295fc9998bd731eb
ENV JCB_PACKAGE https://github.com/joomengine/pkg-component-builder/archive/refs/tags/v5.0.3.zip
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
