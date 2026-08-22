#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v4.1.1 image: extend the official Joomla! v4.4.14 image
# -----------------------------------------------------------------------------
FROM joomla:4.4.14-php8.2-fpm@sha256:a9d698dd21a6bfe49bf6f591c1c70766f77a9d791c7a6e29969a1613cb44ff7a

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v4.4.14 + Component Builder v4.1.1"
LABEL org.opencontainers.image.version="4.1.1"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:4.4.14-php8.2-fpm"
LABEL org.opencontainers.image.base.digest="sha256:a9d698dd21a6bfe49bf6f591c1c70766f77a9d791c7a6e29969a1613cb44ff7a"

# -----------------------------------------------------------------------------
# JCB metadata (required at build-time)
# -----------------------------------------------------------------------------
ENV JCB_VERSION 4.1.1
ENV JCB_SHA512 bfc21e2f63efdff8280959d30a20b4b26448aa8cfb39e02201aee2644fd38b6834271d5eade8a1e2bcfc6fafccf98005d89148078b82cceef0657af71cbf968d
ENV JCB_PACKAGE https://github.com/joomengine/pkg-component-builder/archive/refs/tags/v4.1.1.zip
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
