#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#
# -----------------------------------------------------------------------------
# Official JCB v6.2.0 image: extend the official Joomla! v6.2.0 image
# -----------------------------------------------------------------------------
FROM joomla:6.2.0-php8.3-apache@sha256:ca9f214e6c1fc5ed62d7feefbbc6c551cb4d188e087daff9dafdccd1ac165c05

# Metadata
LABEL maintainer="Llewellyn van der Merwe <llewellyn.van-der-merwe@community.joomla.org> (@Llewellynvdm), Lemuel van der Merwe <lemuel.van-der-merwe@community.joomla.org> (@lemuelvdm)"
LABEL org.opencontainers.image.title="Joomla! Component Builder - JoomEngine"
LABEL org.opencontainers.image.description="Joomla! v6.2.0 + Component Builder v6.2.0"
LABEL org.opencontainers.image.version="6.2.0"
LABEL org.opencontainers.image.source="https://github.com/octoleo/joomengine"
LABEL org.opencontainers.image.base.name="docker.io/library/joomla:6.2.0-php8.3-apache"
LABEL org.opencontainers.image.base.digest="sha256:ca9f214e6c1fc5ed62d7feefbbc6c551cb4d188e087daff9dafdccd1ac165c05"

# -----------------------------------------------------------------------------
# JCB metadata (required at build-time)
# -----------------------------------------------------------------------------
ENV JCB_VERSION 6.2.0
ENV JCB_SHA512 51dcfa77063f03b96bafc64d55e7a7f05ec2984e82a88045604e07d8ce0f8d085c40924736325c72e5306b88f05d172ce657a7e1c8d15ed285cecb8530e74917
ENV JCB_PACKAGE https://github.com/joomengine/pkg-component-builder/archive/refs/tags/v6.2.0.zip
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
