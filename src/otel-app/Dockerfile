FROM node:18-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --omit=dev

COPY . .

RUN addgroup -g 1001 appgroup && \
    adduser -u 1001 -G appgroup -D appuser && \
    chown -R appuser:appgroup /app

USER appuser

EXPOSE 8080

CMD [ "npm", "start" ]
