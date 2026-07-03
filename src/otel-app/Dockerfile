FROM node:22-alpine

WORKDIR /app

COPY package*.json ./
# npm install honours the "overrides" block in package.json (npm >=8.3),
# which pins p-limit to a CommonJS version so @pyroscope/nodejs can require it.
RUN npm install --omit=dev

COPY . .

RUN addgroup -g 1001 appgroup && \
    adduser -u 1001 -G appgroup -D appuser && \
    chown -R appuser:appgroup /app

USER appuser

EXPOSE 8080

CMD [ "npm", "start" ]
