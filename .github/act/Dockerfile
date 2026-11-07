# Runner image for testing the workflows locally with `act` (see .actrc): the
# usual act runner plus Nix, so the nix-installer step (skipped under act) is
# not needed. Build once:  docker build -t ubuntu-act-nix:local .github/act
FROM catthehacker/ubuntu:act-latest
RUN curl -sSfL https://install.determinate.systems/nix | sh -s -- install linux \
      --init none --no-confirm --extra-conf "sandbox = false"
ENV PATH=/nix/var/nix/profiles/default/bin:$PATH
