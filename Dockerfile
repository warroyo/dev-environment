# Test harness for the dotfiles layer — NOT a runtime image.
#
# Applies the chezmoi source directory twice in a clean Ubuntu container to
# prove (a) it applies from nothing, and (b) it is genuinely idempotent, without
# touching a real machine. The provision/ scripts are deliberately not run here:
# they install system packages, write systemd units and rebind sshd, none of
# which belong in a container.
#
#   docker build -t dev-env-test .
#   docker run --rm dev-env-test                  # default: role=restricted
#   docker run --rm -e ROLE=server dev-env-test
#   docker run --rm -e ROLE=personal dev-env-test
#   docker run --rm -e ROLE=work dev-env-test
#
# Exits non-zero if the second apply reports any change, or if a role leaks a
# file it should not have.
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
      zsh git curl ca-certificates zsh-autosuggestions zsh-syntax-highlighting \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /usr/bin/zsh tester
USER tester
WORKDIR /home/tester

RUN sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /home/tester/.local/bin

COPY --chown=tester:tester dotfiles /home/tester/dotfiles-src
COPY --chown=tester:tester test/apply-twice.sh /home/tester/apply-twice.sh

ENV PATH="/home/tester/.local/bin:${PATH}"
ENTRYPOINT ["/home/tester/apply-twice.sh"]
