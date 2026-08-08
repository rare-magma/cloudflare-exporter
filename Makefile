.PHONY: build install uninstall

build:
	@go build -ldflags="-s -w" -o cloudflare_exporter main.go

install: build
	@mkdir --parents $${HOME}/.local/bin $${HOME}/.config/systemd/user \
	&& cp cloudflare_exporter $${HOME}/.local/bin/ \
	&& cp --no-clobber cloudflare_exporter.json $${HOME}/.config/cloudflare_exporter.json \
	&& chmod 400 $${HOME}/.config/cloudflare_exporter.json \
	&& cp cloudflare-exporter.timer cloudflare-exporter.service $${HOME}/.config/systemd/user/ \
	&& systemctl --user enable --now cloudflare-exporter.timer

uninstall:
	@rm -f $${HOME}/.local/bin/cloudflare_exporter \
	&& rm -f $${HOME}/.config/cloudflare_exporter.json \
	&& systemctl --user disable --now cloudflare-exporter.timer \
	&& rm -f $${HOME}/.config/systemd/user/cloudflare-exporter.timer \
	&& rm -f $${HOME}/.config/systemd/user/cloudflare-exporter.service
