#!/bin/bash
# Main Container Creation Script
# Modified June 23rd, 2025 by Maxwell Klema
# ------------------------------------------

# Authenticate User (Only Valid Users can Create Containers)

if [ -z "$PROXMOX_USERNAME" ]; then
	read -p  "Enter Proxmox Username →  " PROXMOX_USERNAME
fi

if [ -z "$PROXMOX_PASSWORD" ]; then
	read -sp "Enter Proxmox Password →  " PROXMOX_PASSWORD
	echo ""
fi

USER_AUTHENTICATED=$(node /root/bin/js/authenticateUserRunner.js authenticateUser "$PROXMOX_USERNAME" "$PROXMOX_PASSWORD")
RETRIES=3

while [ $USER_AUTHENTICATED == 'false' ]; do
	if [ $RETRIES -gt 0 ]; then
		echo "❌ Authentication Failed. Try Again"
		read -p  "Enter Proxmox Username →  " PROXMOX_USERNAME
		read -sp "Enter Proxmox Password →  " PROXMOX_PASSWORD
		echo ""

		USER_AUTHENTICATED=$(node /root/bin/js/authenticateUserRunner.js authenticateUser "$PROXMOX_USERNAME" "$PROXMOX_PASSWORD")
		RETRIES=$(($RETRIES-1))
	else
		echo "Too many incorrect attempts. Exiting..."
		exit 0
	fi
done

echo "🎉 Your proxmox account, $PROXMOX_USERNAME@pve, has been authenticated"

# Gather Container Hostname (hostname.opensource.mieweb.org)

if [ -z "$CONTAINER_NAME" ]; then
	read -p "Enter Application Name (One-Word) →  " CONTAINER_NAME
fi

HOST_NAME_EXISTS=$(ssh root@10.15.20.69 "node /etc/nginx/checkHostnameRunner.js checkHostnameExists ${CONTAINER_NAME}")

while [ $HOST_NAME_EXISTS == 'true' ]; do
	echo "Sorry! That name has already been registered. Try another name"
	read -p "Enter Application Name (One-Word) →  " CONTAINER_NAME
	HOST_NAME_EXISTS=$(ssh root@10.15.20.69 "node /etc/nginx/checkHostnameRunner.js checkHostnameExists ${CONTAINER_NAME}")
done

echo "✅ $CONTAINER_NAME is available"

# Gather Container Password

if [ -z "$CONTAINER_PASSWORD" ]; then
	read -sp "Enter Container Password →  " CONTAINER_PASSWORD
	echo
	read -sp "Confirm Container Password →  " CONFIRM_PASSWORD
	echo

	while [[ "$CONFIRM_PASSWORD" != "$CONTAINER_PASSWORD" || ${#CONTAINER_PASSWORD} -lt 8 ]]; do
        	echo "Sorry, try again. Ensure passwords are at least 8 characters."
        	read -sp "Enter Container Password →  " CONTAINER_PASSWORD
        	echo
        	read -sp "Confirm Container Password →  " CONFIRM_PASSWORD
        	echo
	done
else
	while [ ${#CONTAINER_PASSWORD} -lt 8 ]; do
        	echo "Sorry, try again. Ensure passwords are at least 8 characters."
        	read -sp "Enter Container Password →  " CONTAINER_PASSWORD
        	echo
        	read -sp "Confirm Container Password →  " CONFIRM_PASSWORD
        	echo
	done
fi

# Attempt to detect public keys

echo -e "\n🔑 Attempting to Detect SSH Public Key..."

AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
DETECT_PUBLIC_KEY=$(sudo /root/bin/ssh/detectPublicKey.sh "$SSH_KEY_FP")

if [ "$DETECT_PUBLIC_KEY" == "Public key found for create-container" ]; then
	echo "🔐 Public Key Found!"
else
	echo "🔍 Could not detect Public Key"

	if [ -z "$PUBLIC_KEY" ]; then
		read -p "Enter Public Key (Allows Easy Access to Container) [OPTIONAL - LEAVE BLANK TO SKIP] →  " PUBLIC_KEY
	fi

	# Check if key is valid

	while [[ "$PUBLIC_KEY" != "" && $(echo "$PUBLIC_KEY" | ssh-keygen -l -f - 2>&1 | tr -d '\r') == "(stdin) is not a public key file." ]]; do
		echo "❌ \"$PUBLIC_KEY\" is not a valid key. Enter either a valid key or leave blank to skip."
		read -p "Enter Public Key (Allows Easy Access to Container) [OPTIONAL - LEAVE BLANK TO SKIP] →  " PUBLIC_KEY
	done

	if [ "$PUBLIC_KEY" != "" ]; then
		echo "$PUBLIC_KEY" > "$AUTHORIZED_KEYS" && systemctl restart ssh
		sudo /root/bin/ssh/publicKeyAppendJumpHost.sh "$PUBLIC_KEY"
	fi
fi

# Get HTTP Port Container Listens On

if [ -z "$HTTP_PORT" ]; then
        read -p "Enter HTTP Port for your container to listen on (80-9999) →  " HTTP_PORT
fi

while ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || [ "$HTTP_PORT" -lt 80 ] || [ "$HTTP_PORT" -gt 9999 ]; do
    echo "❌ Invalid HTTP Port. It must be a number between 80 and 9,999."
    read -p "Enter HTTP Port for your container to listen on (80-9999) →  " HTTP_PORT
done

echo "✅ HTTP Port is set to $HTTP_PORT"

# Get any other protocols

protocol_duplicate() {
	PROTOCOL="$1"
	shift #remaining params are part of list
	LIST="$@"

	for item in $LIST; do
		if [[ "$item" == "$PROTOCOL" ]]; then
			return 0 # Protocol is a duplicate
		fi
	done
	return 1 # Protocol is not a duplicate
}

read -p "Does your Container require any protocols other than SSH and HTTP? (y/n) →  " USE_OTHER_PROTOCOLS
while [ "${USE_OTHER_PROTOCOLS^^}" != "Y" ] && [ "${USE_OTHER_PROTOCOLS^^}" != "N" ]; do
	echo "Please answer 'y' for yes or 'n' for no."
	read -p "Does your Container require any protocols other than SSH and HTTP? (y/n) →  " USE_OTHER_PROTOCOLS
done

RANDOM_NUM=$(shuf -i 100000-999999 -n 1)
PROTOCOL_FILE="/root/bin/protocols/protocol_list_$RANDOM_NUM.txt"

if [ "${USE_OTHER_PROTOCOLS^^}" == "Y" ]; then
	LIST_PROTOCOLS=()
	read -p "Enter the protocol abbreviation (e.g, LDAP for Lightweight Directory Access Protocol). Type \"e\" to exit →  " PROTOCOL_NAME
	while [ "${PROTOCOL_NAME^^}" != "E" ]; do
		FOUND=0 #keep track if protocol was found
		while read line; do
			PROTOCOL_ABBRV=$(echo "$line" | awk '{print $1}')
			protocol_duplicate "$PROTOCOL_ABBRV" "${LIST_PROTOCOLS[@]}"
			IS_PROTOCOL_DUPLICATE=$?	
			if [[ "$PROTOCOL_ABBRV" == "${PROTOCOL_NAME^^}" && "$IS_PROTOCOL_DUPLICATE" -eq 1 ]]; then
				LIST_PROTOCOLS+=("$PROTOCOL_ABBRV")
				PROTOCOL_UNDRLYING_NAME=$(echo "$line" | awk '{print $3}')
				PROTOCOL_DEFAULT_PORT=$(echo "$line" | awk '{print $2}')
				echo "$PROTOCOL_ABBRV $PROTOCOL_UNDRLYING_NAME $PROTOCOL_DEFAULT_PORT" >> "$PROTOCOL_FILE"
				echo "✅ Protocol ${PROTOCOL_NAME^^} added to container."
				FOUND=1 #protocol was found
				break
			else
				echo "❌ Protocol ${PROTOCOL_NAME^^} was already added to your container. Please try again."
				FOUND=2 #protocol was a duplicate
				break
			fi
		done < <(cat "/root/bin/protocols/master_protocol_list.txt" | grep "^${PROTOCOL_NAME^^}") 

		if [ $FOUND -eq 0 ]; then #if no results found, let user know.
			echo "❌ Protocol ${PROTOCOL_NAME^^} not found. Please try again."
		fi

		read -p "Enter the protocol abbreviation (e.g, LDAP for Lightweight Directory Access Protocol). Type \"e\" to exit →  " PROTOCOL_NAME
	done
fi

# ssh into hypervisor, Cresate the Container, run port mapping script

rm -rf "$PROTOCOL_FILE"
unset CONFIRM_PASSWORD
unset CONTAINER_PASSWORD