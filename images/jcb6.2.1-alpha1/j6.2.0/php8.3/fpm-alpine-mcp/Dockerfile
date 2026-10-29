#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v6.2.1-alpha1 image: extend the official Joomla! v6.2.0 image
# -----------------------------------------------------------------------------
FROM joomla:6.2.0-php8.3-fpm-alpine@sha256:868c0738ffe1e6091b35a229722ed2394b63cf8acf4db5849b7f5c46f967c416

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v6.2.0 + Component Builder v6.2.1-alpha1 + JoomEngine MCP v1.0.10"
LABEL org.opencontainers.image.version="6.2.1-alpha1"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:6.2.0-php8.3-fpm-alpine"
LABEL org.opencontainers.image.base.digest="sha256:868c0738ffe1e6091b35a229722ed2394b63cf8acf4db5849b7f5c46f967c416"

# -----------------------------------------------------------------------------
# JCB metadata (required at build-time)
# -----------------------------------------------------------------------------
ENV JCB_VERSION 6.2.1-alpha1
ENV JCB_SHA512 f36c012949cc113c82a8ecb00cddb7c23a5aae647b6767f3c4514cbff3ef3f217ce6a2c35f34668a324a36755194a992a51d1e8eb141708c2140d8e874dd6c35
ENV JCB_PACKAGE https://github.com/joomengine/pkg-component-builder/archive/refs/tags/v6.2.1-alpha1.zip
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
# Optional JoomEngine MCP package (component and plugins, pinned at image build)
# -----------------------------------------------------------------------------
LABEL org.joomengine.mcp.version="1.0.10"
LABEL org.joomengine.mcp.sha512="2eeffc65c2559bc36a602c2273e474d92b0b060522f90357c3b8f368b5f68904544946ebcd809bbebf8d68ef27536179e00e093c1b5de6f4bfba3b99c210dabb"
LABEL org.joomengine.mcp.source="https://github.com/joomengine/mcp_package/archive/refs/tags/v1.0.10.zip"
ENV MCP_VERSION=1.0.10
ENV MCP_SHA512=2eeffc65c2559bc36a602c2273e474d92b0b060522f90357c3b8f368b5f68904544946ebcd809bbebf8d68ef27536179e00e093c1b5de6f4bfba3b99c210dabb
ENV MCP_PACKAGE=https://github.com/joomengine/mcp_package/archive/refs/tags/v1.0.10.zip

RUN set -eux; \
	curl -fSL "$MCP_PACKAGE" -o "$JCB_INSTALL_DIR/mcp.zip"; \
	echo "$MCP_SHA512  $JCB_INSTALL_DIR/mcp.zip" | sha512sum -c -; \
	chown www-data:www-data "$JCB_INSTALL_DIR/mcp.zip"

# -----------------------------------------------------------------------------
# JCB entrypoint
# -----------------------------------------------------------------------------
COPY docker-entrypoint.sh /entrypoint.sh
RUN set -eux; \
	chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]
