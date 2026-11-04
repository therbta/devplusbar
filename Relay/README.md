# Dev+ Bar webhook relay (optional)

Dev+ Bar has no server; it polls Vercel and Heroku with your own tokens (every 15 s while
something builds). If you want updates within ~5 s at all times, host this tiny relay yourself.
It never sees your API tokens and stores one timestamp — no payloads.

## Deploy

```sh
cd Relay
wrangler kv namespace create RELAY          # paste the id into wrangler.toml
wrangler secret put VERCEL_SECRET           # from the Vercel webhook you create below
wrangler secret put HEROKU_SECRET           # the secret Heroku prints when you add the webhook
wrangler secret put READ_TOKEN              # random string; part of the app's relay URL
wrangler deploy
```

## Point the providers at it

- Vercel: Team Settings › Webhooks › `https://<worker>/hook/vercel`, events
  `deployment.created`, `deployment.succeeded`, `deployment.error`, `deployment.canceled`.
  Vercel shows the signing secret once; that is `VERCEL_SECRET`.
- Heroku, per app:
  `heroku webhooks:add -i api:build,api:release -l notify -u https://<worker>/hook/heroku -a <app>`
  (it prints a secret; store it as `HEROKU_SECRET`, and add the same webhook to each app)

## Point Dev+ Bar at it

Settings › Deployments › Advanced › Webhook relay URL: `https://<worker>/<READ_TOKEN>`.
