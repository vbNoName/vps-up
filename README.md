# Настройка чистой vps + 3xui

## Базовая конфигурация

1) Поменять пароль от root юзера
    ```shell
    passwd
    ```
   
1) Обновить систему
    ```shell
    apt update && apt upgrade -y
    ```
   
1) Установить минимально необходимые пакеты
    ```shell
    apt install vim wget git
    ```
   
1) Добавить нового юзера
   
   В качестве примера используется юзер с именем `username`
    ```shell
    adduser username
    ```
    И выдать ему sudo
    ```shell
   usermod -aG sudo username
   ```
   
1) Авторизоваться под новым юзером и проверить работоспособность sudo
   ```shell
   sudo touch /opt/tmp.txt && sudo rm /opt/tmp.txt
   ```

1) Сменить ssh порт и запретить авторизацию под root по ssh
   ```shell
   sudo vi /etc/ssh/sshd_config
   ```
   Раскомментировать следующие строки и указать значения
   ```
   Port {PORT}
   PermitRootLogin no
   ```
   Перезапустить sshd. После перезапуска подключиться к vps по новому порту
   ```shell
   sudo systemctl daemon-reload
   sudo systemctl restart ssh.socket
   sudo systemctl restart ssh.service
   ```

1) Положить [.bashrc](./config/.bashrc) файл в домашний каталог юзера
```shell
wget -O ~/.bashrc https://raw.githubusercontent.com/vbNoName/vps-up/main/config/.bashrc
```
Перелогиниться

## Firewall

Установить
```shell
sudo apt install ufw
```

Открыть порты
```shell
sudo ufw allow 80
```
```shell
sudo ufw allow 443
```
```shell
sudo ufw allow ssh_port
```
```shell
sudo ufw allow 3xui_panel_port
```
```shell
sudo ufw enable
```

## 3x-ui

Установить и настроить по инструкции - https://github.com/MHSanaei/3x-ui

Доступы к панели будут выведены в лог во время установки.

Дополнительно можно включить
* Fail2ban и IP Limit
* BBR

## Selfsteal (свой сайт и сертификат для Reality)

Скрипт [setup-selfsteal.sh](./scripts/setup-selfsteal.sh) ставит nginx с сайтом-заглушкой и сертификатом Let's Encrypt
на `127.0.0.1:8443` и проксирует туда панель 3x-ui по секретному пути того же домена.
Reality inbound на 443 потом пересылает чужие подключения на этот nginx.
Inbound'ы, настройки панели, Xray и файрвол скрипт не меняет: что сделать вручную, он выведет в конце.

Подробно: [docs/selfsteal.md](./docs/selfsteal.md)

```shell
curl -fsSL https://raw.githubusercontent.com/vbNoName/vps-up/main/scripts/setup-selfsteal.sh | sudo bash -s -- --domain vpn.example.com --panel-port 2053 --panel-path /secret-path/ --email admin@example.com
```
