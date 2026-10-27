#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v6.1.6 image: extend the official Joomla! v6.2.0 image
# -----------------------------------------------------------------------------
FROM joomla:6.2.0-php8.4-apache@sha256:3ae5573340b69391dd23497dbb650c557aa3a72de71fd8bd47bd0621484d2321

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v6.2.0 + Component Builder v6.1.6 + JoomEngine MCP v1.0.10"
LABEL org.opencontainers.image.version="6.1.6"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:6.2.0-php8.4-apache"
LABEL org.opencontainers.image.base.digest="sha256:3ae5573340b69391dd23497dbb650c557aa3a72de71fd8bd47bd0621484d2321"

# -----------------------------------------------------------------------------
# JCB metadata (required at build-time)
# -----------------------------------------------------------------------------
ENV JCB_VERSION 6.1.6
ENV JCB_SHA512 18ed748c57ab8c0c1c28053795f22fc0526f8ef3309cacedbbc9a46619d3bb345c94d687fcc42aba2c93ca8a9c29c7720a6ccf649618c5c6cd89158062fc312c
ENV JCB_PACKAGE https://github.com/joomengine/pkg-component-builder/archive/refs/tags/v6.1.6.zip
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
CMD ["apache2-foreground"]
