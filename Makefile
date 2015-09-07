all:

WGET = wget
CURL = curl
GIT = git

updatenightly: local/bin/pmbp.pl
	$(CURL) -s -S -L https://gist.githubusercontent.com/wakaba/34a71d3137a52abb562d/raw/gistfile1.txt | sh
	$(GIT) add t_deps/modules
	perl local/bin/pmbp.pl --update
	$(GIT) add config

# ------ Setup ------

deps: git-submodules pmbp-install

git-submodules:
	$(GIT) submodule update --init

local/bin/pmbp.pl:
	mkdir -p local/bin
	$(WGET) -O $@ https://raw.github.com/wakaba/perl-setupenv/master/bin/pmbp.pl

pmbp-upgrade: local/bin/pmbp.pl
	perl local/bin/pmbp.pl --update-pmbp-pl

pmbp-update: pmbp-upgrade
	perl local/bin/pmbp.pl \
	    --update

pmbp-install: pmbp-upgrade
	perl local/bin/pmbp.pl --install \
	    --install-apache 2.2 \
            --create-perl-command-shortcut perl \
            --create-perl-command-shortcut prove \
            --create-perl-command-shortcut local/bin/which \
            --add-to-gitignore /perl \
            --add-to-gitignore /prove

# ------ Tests ------

PROVE = ./prove

test: test-deps test-main

test-deps: deps

test-main:
	$(PROVE) t/*.t

## License: Public Domain.