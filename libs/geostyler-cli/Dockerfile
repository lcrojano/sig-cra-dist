FROM node:20-alpine

WORKDIR /app

# Install geostyler-cli globally
RUN npm install -g geostyler-cli

# Copy your input files
COPY . .

# ✅ Add www-data user with UID 33, but do NOT create group if it exists
RUN adduser -D -u 33 -G www-data www-data

USER www-data

ENTRYPOINT ["geostyler-cli"]
