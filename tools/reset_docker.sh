
#!/bin/bash

# Function to display messages in red
function echo_red() {
    echo -e "\e[31m$1\e[0m"
}

# Prompt the user for confirmation
echo_red "Are you sure you wish to reset docker on your computer?\nType yes if you want all your docker images and any work you've done removed!"
read -r confirmation

# Check the user's response
if [[ "$confirmation" == "yes" ]]; then
    # Stop all running Docker containers
    docker stop $(docker ps -aq)

    # Remove all Docker containers
    docker rm $(docker ps -aq)

    # Remove all Docker images
    docker rmi -f $(docker images -q)

    # Remove all Docker volumes
    docker volume rm $(docker volume ls -q)

    # Remove all Docker networks
    docker network rm $(docker network ls -q)

    # Remove any dangling resources
    docker system prune -af
    docker volume prune -f
    docker network prune -f

    echo "Docker reset complete."
else
    echo "Operation aborted. No changes were made."
fi

