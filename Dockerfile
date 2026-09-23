ARG UPSTREAM_VERSION
# hoprd-pix-test, not hoprd: the plain image enables no PIX pool feature, so it inherits
# hopr-lib's default `pix-bjj` and announces BabyJubJub as its PIX curve suite.
# Change back to `hoprd` once Curvy pool is ready
FROM europe-west3-docker.pkg.dev/hoprassociation/docker-images/hoprd-pix-test:${UPSTREAM_VERSION}

# not used at the moment, but might be useful in the future
ENV DAPPNODE=true

ADD hoprd.cfg.yaml.tpl /app/hoprd.cfg.yaml.tpl
ADD entrypoint.sh /bin/entrypoint.sh

RUN chmod +rx /bin/entrypoint.sh

ENTRYPOINT ["/bin/entrypoint.sh"]
