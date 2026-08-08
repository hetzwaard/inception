NAME    = inception
COMPOSE = docker compose -f srcs/docker-compose.yml
DATA    = /home/$(USER)/data

all: up

$(DATA):
	@mkdir -p $(DATA)/mariadb $(DATA)/wordpress

build: $(DATA)
	$(COMPOSE) build

up: $(DATA)
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

stop:
	$(COMPOSE) stop

start:
	$(COMPOSE) start

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

clean: down
	$(COMPOSE) down --volumes --remove-orphans

fclean: clean
	@docker system prune -af
	@sudo rm -rf $(DATA)/mariadb $(DATA)/wordpress

re: fclean all

.PHONY: all build up down stop start logs ps clean fclean re
