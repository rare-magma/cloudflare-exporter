.PHONY: install
install:
	@mkdir --parents $${HOME}/.local/bin \
	&& mkdir --parents $${HOME}/.config/systemd/user \
	&& cp cloudflare_exporter.sh $${HOME}/.local/bin/ \
	&& chmod +x $${HOME}/.local/bin/cloudflare_exporter.sh \
	&& cp --no-clobber cloudflare_exporter.conf $${HOME}/.config/cloudflare_exporter.conf \
	&& cp --no-clobber cloudflare_zone_list.json $${HOME}/.config/cloudflare_zone_list.json \
	&& chmod 400 $${HOME}/.config/cloudflare_exporter.conf \
	&& cp cloudflare-exporter.timer $${HOME}/.config/systemd/user/ \
	&& cp cloudflare-exporter.service $${HOME}/.config/systemd/user/ \
	&& systemctl --user enable --now cloudflare-exporter.timer

.PHONY: uninstall
uninstall:
	@rm -f $${HOME}/.local/bin/cloudflare_exporter.sh \
	&& rm -f $${HOME}/.config/cloudflare_exporter.conf \
	&& rm -f $${HOME}/.config/cloudflare_zone_list.json \
	&& systemctl --user disable --now cloudflare-exporter.timer \
	&& rm -f $${HOME}/.config/.config/systemd/user/cloudflare-exporter.timer \
	&& rm -f $${HOME}/.config/systemd/user/cloudflare-exporter.service
