#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v6.1.6 image: extend the official Joomla! v6.1.4 image
# -----------------------------------------------------------------------------
FROM joomla:6.1.4-php8.4-fpm@sha256:2b1421965721a6a9979745f4b78e59578fc6502176ae3feaed7dc90c3498f236

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v6.1.4 + Component Builder v6.1.6 + JoomEngine MCP v1.0.7"
LABEL org.opencontainers.image.version="6.1.6"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:6.1.4-php8.4-fpm"
LABEL org.opencontainers.image.base.digest="sha256:2b1421965721a6a9979745f4b78e59578fc6502176ae3feaed7dc90c3498f236"

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
LABEL org.joomengine.mcp.version="1.0.7"
LABEL org.joomengine.mcp.sha512="3472ddd6b6c21a5677667dc8f6a54abb8768972f7e95ac23261a5c7ad66503ac296650c52c1b6eba74607473f4c06027a55a6598ad039df6ea0a6bc1a2cfc89f"
LABEL org.joomengine.mcp.source="https://github.com/joomengine/mcp_package/archive/refs/tags/v1.0.7.zip"
ENV MCP_VERSION=1.0.7
ENV MCP_SHA512=3472ddd6b6c21a5677667dc8f6a54abb8768972f7e95ac23261a5c7ad66503ac296650c52c1b6eba74607473f4c06027a55a6598ad039df6ea0a6bc1a2cfc89f
ENV MCP_PACKAGE=https://github.com/joomengine/mcp_package/archive/refs/tags/v1.0.7.zip

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
