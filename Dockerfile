FROM ghcr.io/anyakichi/myenv:slim

RUN \
  pacman --noconfirm -Syu \
  && pacman --noconfirm -S \
    bash-language-server \
    clang \
    docker \
    gopls \
    lua-language-server \
    prettier \
    pyright \
    rust-analyzer \
    typescript \
  && rm -rf /var/cache/pacman/pkg/* \
  && gpasswd -a $BUILD_USER docker

USER $BUILD_USER
RUN \
  pwd \
  && git clone https://aur.archlinux.org/yay.git \
  && cd yay \
  && makepkg --noconfirm -si \
  && yay --noconfirm -S \
    reason-language-server \
  && yay --noconfirm -Sc \
  && sudo pacman --noconfirm -Rcsn $(pacman -Qdtq) \
  && sudo rm -rf /var/cache/pacman/pkg/* ~/.cache/go-build ~/yay

USER root
