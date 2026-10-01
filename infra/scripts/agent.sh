#!/bin/sh
# Отправить команду bsdOS guest agent через vsock.
# Использование: ./agent.sh <hex-bytes>
# Пример PING: ./agent.sh '\x01\x00\x00\x00'
# Требует: socat, guest CID известен
CMD="${1:-\x01\x00\x00\x00}"
GUEST_CID="${GUEST_CID:-3}"
# Импортируем AGENT_SVC из svc_id — значение вычислено при компиляции
# Для тестирования укажи AGENT_SVC=<hash> или используй build-agent для получения значения
AGENT_SVC="${AGENT_SVC:-1073741824}"
printf "$CMD" | socat - "VSOCK-CONNECT:${GUEST_CID}:${AGENT_SVC}"
