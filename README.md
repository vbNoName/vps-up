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