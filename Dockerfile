FROM ghcr.io/anyakichi/myenv:slim

RUN \
  pacman --noconfirm -Syu \
  && pacman --noconfirm -S \
    bash-language-server \
    clang \
    docker \
    gopls \
    lua-language-server \
    npm \
    prettier \
    pyright \
    rust-analyzer \
    typescript \
  && rm -rf /var/cache/pacman/pkg/* \
  && gpasswd -a $BUILD_USER docker

USER $BUILD_USER
RUN \
  nvim -c "set nomore" +"TSInstallSync all" +qall

USER root
