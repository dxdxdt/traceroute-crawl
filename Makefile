PREFIX ?= /usr/local

.PHONY: install uninstall

install:
	mkdir -p ${PREFIX}/share/doc
	mkdir -p /etc/traceroute-crawl/site.conf.d
	chmod 700 /etc/traceroute-crawl
	mkdir -p ${PREFIX}/lib/systemd/system
	mkdir -p ${PREFIX}/bin
	install -m 644 traceroute-crawl.sample.conf ${PREFIX}/share/doc/traceroute-crawl
	test -f /etc/traceroute-crawl/traceroute-crawl.conf || \
		install -m 644 traceroute-crawl.sample.conf /etc/traceroute-crawl/traceroute-crawl.conf
	install -m 644 traceroute-crawl.service traceroute-crawl@.service ${PREFIX}/lib/systemd/system
	install -m 755 traceroute-crawl.sh traceroute-crawl ${PREFIX}/bin
	systemctl daemon-reload

uninstall:
	rm -f \
		${PREFIX}/bin/traceroute-crawl.sh \
		${PREFIX}/bin/traceroute-crawl \
		${PREFIX}/lib/systemd/system/traceroute-crawl.service \
		${PREFIX}/lib/systemd/system/traceroute-crawl@.service
	systemctl daemon-reload
