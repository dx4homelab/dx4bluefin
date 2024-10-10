cd ..

curl -L -o mods/main.zip https://github.com/ublue-os/bluefin/archive/refs/heads/main.zip

unzip -o mods/main.zip

find . -maxdepth 1 -type d -not -path '.' | grep -vE '^\.$|^\./mods|^\./\.git$' | xargs -n1  echo found # rm -rf

# find . -maxdepth 1 -type d -not -path '.' | grep -vE '^\.$|^\./mods|^\./\.git$' | xargs -n1 rm -rf

# find . -maxdepth 1 -type d -not -path '.' | grep -vE '^\.$|^\./mods|^\./\.git$' | xargs -n1  echo found # rm -rf

cd mods

