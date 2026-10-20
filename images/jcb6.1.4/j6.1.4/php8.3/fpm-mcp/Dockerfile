#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v6.1.4 image: extend the official Joomla! v6.1.4 image
# -----------------------------------------------------------------------------
FROM joomla:6.1.4-php8.3-fpm@sha256:a92d895df500063ba4d62e6c0f0f35343d250985934547c202cf0059b6c85b36

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v6.1.4 + Component Builder v6.1.4 + JoomEngine MCP v1.0.10"
LABEL org.opencontainers.image.version="6.1.4"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:6.1.4-php8.3-fpm"
LABEL org.opencontainers.image.base.digest="sha256:a92d895df500063ba4d62e6c0f0f35343d250985934547c202cf0059b6c85b36"

# -----------------------------------------------------------------------------
# JCB metadata (required at build-time)
# -----------------------------------------------------------------------------
ENV JCB_VERSION 6.1.4
ENV JCB_SHA512 cde289bdd21689dcb90ac68d44573ce52c0ff861ff02780327b1ff7f3a58918ddcf010f1e4a2b79af17cd91bf33ee4b81d99a8be9d98ce81e560614bd26d6a66
ENV JCB_PACKAGE https://github.com/joomengine/pkg-component-builder/archive/refs/tags/v6.1.4.zip
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

# JCB jobs launch a detached CLI worker. The official PHP/Joomla base does not
# enable PCNTL; docker-php-ext-install also manages Alpine's temporary build deps.
RUN set -eux; \
	docker-php-ext-install -j "$(nproc)" pcntl; \
	php -r 'foreach (["pcntl_fork", "posix_setsid", "proc_open"] as $function) { if (!function_exists($function)) { fwrite(STDERR, "Missing MCP worker function: " . $function . PHP_EOL); exit(1); } }'

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
