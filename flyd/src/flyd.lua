#!/usr/bin/env tarantool

local fio	= require('fio')
local log	= require('log')
local uuid	= require('uuid')
local json	= require('json')
local fiber	= require('fiber')
local queue	= require('queue')
local client	= require('http.client')
local console	= require('console')

---------------------------------------
--             Arguments
---------------------------------------
local path2config = arg[1] or '/usr/local/etc/flyd/flyd.conf'
if not fio.stat(path2config) then
	path2config = 'conf/flyd.conf'
end

---------------------------------------
--             Constants
---------------------------------------
local FLYD_STATUS = {
	ACTIVE		= 1,
	REGISTER_CB	= 2,
	DONE		= 3,
	ERROR		= 4,
	RETRY		= 5,
	RETRY_CB	= 6,
}

local QUERY_IDX = {
	CARRIER	= 1,
	FLIGHT	= 2,
	DAY	= 3,
	MONTH	= 4,
	YEAR	= 5,
	STATUS	= 6,
	ID	= 7
}

local FLIGHT_IDX = {
	ID		= 1,
	CARRIER		= 2,
	FLIGHT		= 3,
	DEP_CODE	= 4,
	ARR_CODE	= 5,
	DEP_DATE	= 6,
	ARR_DATE	= 7,
	DEP_GATE	= 8,
	ARR_GATE	= 9,
	DEP_TERM	= 10,
	ARR_TERM	= 11,
	STATUS		= 12,
}

local RESERVATION_STATUS = {
	CONFIRMED = 1,
	CANCELLED = 2,
}

local RESERVATION_STATUS_STR = {
	'http://schema.org/ReservationConfirmed',
	'http://schema.org/ReservationCancelled'
}

local LOCALE = {
	RU	= 'ru',
	EN	= 'en'
}

---------------------------------------
--             Private functions
---------------------------------------

local function flyd_process_update_cancelled(flight)
	local upd = flights:update(flight[FLIGHT_IDX.ID], {{'=', FLIGHT_IDX.STATUS, RESERVATION_STATUS.CANCELLED}})
	assert(upd, 'update should be successfull')

	return { status = 200 }
end

local function flyd_process_update_diverted(flight, rule, fs)
	local func = 'flyd_process_update_diverted'

	local carrier, fnum, day, month, year, need_insert
	local r2upd = {}

	carrier = flight[FLIGHT_IDX.CARRIER]
	if rule.carrier and rule.carrier.iata then
		carrier = rule.carrier.iata
	elseif fs.carrier and fs.carrier.iata then
		carrier = fs.carrier.iata
	end
	if carrier ~= flight[FLIGHT_IDX.CARRIER] then
		assert(carrier ~= nil)
		table.insert(r2upd, {'=', FLIGHT_IDX.CARRIER, carrier})
		need_insert = true
	end

	fnum = rule.flightNumber or fs.flightNumber or flight[FLIGHT_IDX.FLIGHT]
	if fnum ~= flight[FLIGHT_IDX.FLIGHT] then
		assert(fnum ~= nil)
		table.insert(r2upd, {'=', FLIGHT_IDX.FLIGHT, fnum})
		need_insert = true
	end

	local departure_iata = flight[FLIGHT_IDX.DEP_CODE]
	local departureAirport = rule.departureAirport or fs.departureAirport
	if departureAirport then
		departure_iata = departureAirport.iata or departure_iata
	end
	if departure_iata ~= flight[FLIGHT_IDX.DEP_CODE] then
		assert(departure_iata ~= nil)
		table.insert(r2upd, {'=', FLIGHT_IDX.DEP_CODE, departure_iata})
	end

	local arrival_iata = flight[FLIGHT_IDX.ARR_CODE]
	local arrivalAirport = rule.arrivalAirport or fs.arrivalAirport
	if arrivalAirport then
		arrival_iata = arrivalAirport.iata or arrival_iata
	end
	if arrival_iata ~= flight[FLIGHT_IDX.ARR_CODE] then
		assert(arrival_iata ~= nil)
		table.insert(r2upd, {'=', FLIGHT_IDX.ARR_CODE, arrival_iata})
	end

	local departure_date = rule.departure or
			       (fs.departureDate and fs.departureDate.dateLocal) or
			       flight[FLIGHT_IDX.DEP_DATE]
	if departure_date ~= flight[FLIGHT_IDX.DEP_DATE] then
		assert(departure_date ~= nil)
		table.insert(r2upd, {'=', FLIGHT_IDX.DEP_DATE, departure_date})
		need_insert = true
	end

	local arrival_date = rule.arrival or
			     (fs.arrivalDate and fs.arrivalDate.dateLocal) or
			     flight[FLIGHT_IDX.ARR_DATE]
	if arrival_date ~= flight[FLIGHT_IDX.ARR_DATE] then
		assert(arrival_date ~= nil)
		table.insert(r2upd, {'=', FLIGHT_IDX.ARR_DATE, arrival_date})
	end

	local airportResources = fs.airportResources or {}
	local departure_gate = airportResources.departureGate or flight[FLIGHT_IDX.DEP_GATE]
	if departure_gate and departure_gate ~= flight[FLIGHT_IDX.DEP_GATE] then
		table.insert(r2upd, {'=', FLIGHT_IDX.DEP_GATE, departure_gate})
	end

	local departure_term = airportResources.departureTerminal or flight[FLIGHT_IDX.DEP_TERM]
	if departure_term and departure_term ~= flight[FLIGHT_IDX.DEP_TERM] then
		table.insert(r2upd, {'=', FLIGHT_IDX.DEP_TERM, departure_term})
	end

	local arrival_gate = airportResources.arrivalGate or flight[FLIGHT_IDX.ARR_GATE]
	if arrival_gate and arrival_gate ~= flight[FLIGHT_IDX.ARR_GATE] then
		table.insert(r2upd, {'=', FLIGHT_IDX.ARR_GATE, arrival_gate})
	end

	local arrival_term = airportResources.arrivalTerminal or flight[FLIGHT_IDX.ARR_TERM]
	if arrival_term and arrival_term ~= flight[FLIGHT_IDX.ARR_TERM] then
		table.insert(r2upd, {'=', FLIGHT_IDX.ARR_TERM, arrival_term})
	end

	if #r2upd == 0 then
		log.info("%s: flight `%u': nothing to update (diverted)", func, flight[FLIGHT_IDX.ID])
		return { status = 200 }
	end

	for i = 1,#r2upd do
		log.debug("%s: flight `%u': field `%s' will be set to `%s'",
			  func, flight[FLIGHT_IDX.ID], r2upd[i][2], r2upd[i][3])
	end

	local ok, ret = pcall(flights.update, flights, flight[FLIGHT_IDX.ID], r2upd)
	if not ok then
		log.error("%s: flight `%u': update failed: %s", func, flight[FLIGHT_IDX.ID], ret)
		return { status = 400 }
	end

	if not need_insert then
		return { status = 200 }
	end

	year, month, day = string.match(departure_date, "^(%d+)-(%d+)-(%d+)")
	if not year then
		log.error("%s: flight `%u': can't parse date `%s'", func, flight[FLIGHT_IDX.ID], departure_date)
		return { status = 400 }
	end

	assert(month ~= nil and day ~= nil)
	ok, ret = pcall(query.insert, query, {
		carrier, tonumber(fnum), tonumber(day), tonumber(month),
		tonumber(year), FLYD_STATUS.DONE, flight[FLIGHT_IDX.ID]
	})
	if not ok then
		log.error("%s: flight `%u': query insert failed: %s", func, flight[FLIGHT_IDX.ID], ret)
	end

	return { status = 200 }
end

local function flyd_process_update_arrival_gate(flight, fs)
	local func = 'flyd_process_update_arrival_gate'

	if not fs.airportResources then
		log.warn("%s: can't update arrival gate for flight `%u': `airportResources' missed",
			 func, flight[FLIGHT_IDX.ID])

		return { status = 400 }
	end

	local upd = {}
	if fs.airportResources.arrivalGate and
	   fs.airportResources.arrivalGate ~= flight[FLIGHT_IDX.ARR_GATE] then
		log.info("%s: flight `%u': arrivalGate set to `%s'",
			 func, flight[FLIGHT_IDX.ID], fs.airportResources.arrivalGate)

		table.insert(upd, { '=', FLIGHT_IDX.ARR_GATE, fs.airportResources.arrivalGate })
	end
	if fs.airportResources.arrivalTerminal and
	   fs.airportResources.arrivalTerminal ~= flight[FLIGHT_IDX.ARR_TERM] then
		log.info("%s: flight `%u': arrivalTerminal set to `%s'",
			 func, flight[FLIGHT_IDX.ID], fs.airportResources.arrivalTerminal)

		table.insert(upd, { '=', FLIGHT_IDX.ARR_TERM, fs.airportResources.arrivalTerminal })
	end

	if #upd == 0 then
		log.info("%s: flight `%u': nothing to update (arrival gate)", func, flight[FLIGHT_IDX.ID])
		return { status = 200 }
	end

	local ok, ret = pcall(flights.update, flights, flight[FLIGHT_IDX.ID], upd)
	if not ok then
		log.error("%s: flight `%u', update failed: %s", func, flight[FLIGHT_IDX.ID], ret)
		return { status = 400 }
	end

	log.info("%s: flight `%u': update success", func, flight[FLIGHT_IDX.ID])

	return { status = 200 }
end

local function flyd_process_update_departure_gate(flight, fs)
	local func = 'flyd_process_update_departure_gate'

	if not fs.airportResources then
		log.warn("%s: can't update departure gate for flight `%u': `airportResources' missed",
			 func, flight[FLIGHT_IDX.ID])

		return { status = 400 }
	end

	local upd = {}
	if fs.airportResources.departureGate and
	   fs.airportResources.departureGate ~= flight[FLIGHT_IDX.DEP_GATE] then
		log.info("%s: flight `%u': departureGate set to `%s'",
			 func, flight[FLIGHT_IDX.ID], fs.airportResources.departureGate)

		table.insert(upd, { '=', FLIGHT_IDX.DEP_GATE, fs.airportResources.departureGate })
	end
	if fs.airportResources.departureTerminal and
	   fs.airportResources.departureTerminal ~= flight[FLIGHT_IDX.DEP_TERM] then
		log.info("%s: flight `%u': departureTerminal set to `%s'",
			 func, flight[FLIGHT_IDX.ID], fs.airportResources.departureTerminal)

		table.insert(upd, { '=', FLIGHT_IDX.DEP_TERM, fs.airportResources.departureTerminal })
	end

	if #upd == 0 then
		log.info("%s: flight `%u': nothing to update (departure gate)", func, flight[FLIGHT_IDX.ID])
		return { status = 200 }
	end

	local ok, ret = pcall(flights.update, flights, flight[FLIGHT_IDX.ID], upd)
	if not ok then
		log.error("%s: flight `%u', update failed: %s", func, flight[FLIGHT_IDX.ID], ret)
		return { status = 400 }
	end

	log.info("%s: flight `%u': update success", func, flight[FLIGHT_IDX.ID])

	return { status = 200 }
end

local function flyd_process_update_delay(flight, rule, fs)
	local func = 'flyd_process_update_delay'

	local departure_date = rule.departure or (fs.departureDate and fs.departureDate.dateLocal)
	if not departure_date then
		log.error("%s: flight `%u': got departure delay update, but new departure date not found",
			  func, flight[FLIGHT_IDX.ID])

		return { status = 400 }
	end

	if flight[FLIGHT_IDX.DEP_DATE] == departure_date then
		log.info("%s: flight `%u': nothing to update (delay)", func, flight[FLIGHT_IDX.ID])
		return { status = 200 }
	end

	local year, month, day = string.match(departure_date, "^(%d+)-(%d+)-(%d+)")
	if not year then
		log.error("%s: flight `%u': can't parse date `%s'", func, flight[FLIGHT_IDX.ID], departure_date)
		return { status = 400 }
	end

	local upd = flights:update(flight[FLIGHT_IDX.ID], {{ '=', FLIGHT_IDX.DEP_DATE, departure_date }})
	-- assert(udp ~= nil, 'update should be success') -- XXX: why this function returns `nil' ???

	local ok, ret = pcall(query.insert, query, {
		flight[FLIGHT_IDX.CARRIER], tonumber(flight[FLIGHT_IDX.FLIGHT]),
		tonumber(day), tonumber(month), tonumber(year), FLYD_STATUS.DONE, flight[FLIGHT_IDX.ID]
	})
	if not ok then
		log.error("%s: insert {%s,%s,%s,%s,%s} for `%u' failed: %s",
			  func, flight[FLIGHT_IDX.CARRIER], flight[FLIGHT_IDX.FLIGHT],
			  day, month, year, flight[FLIGHT_IDX.ID], ret)

		return { status = 200 }
	end

	return { status = 200 }
end

local function flyd_validate_alert_json(json)
	local func = 'flyd_validate_alert_json'

	if not json.alert then
		log.error("%s: got invalid json inside callback: missed `alert' field", func)
		return false
	elseif not json.alert.event then
		log.error("%s: got invalid json inside callback: missed `alert.event' field", func)
		return false
	elseif not json.alert.rule then
		log.error("%s: got invalid json inside callback: missed `alert.rule' field", func)
		return false
	elseif not json.alert.flightStatus then
		log.error("%s: got invalid json inside callback: missed `alert.flightStatus' field", func)
		return false
	end

	local t = json.alert.event.type
	if t ~= 'CANCELLED' and t ~= 'DIVERTED' and t ~= 'DEPARTURE_DELAY' and
	   t ~= 'DEPARTURE_GATE' and t ~= 'ARRIVAL_GATE' then
		log.error("%s: got unknown notify event type: `%s'", func, t)
		return false
	end

	return true
end

local function flyd_process_update(flight, json)
	local func = 'flyd_process_update'

	if not flyd_validate_alert_json(json) then
		return { status = 400 }
	end

	local t = json.alert.event.type
	local rule = json.alert.rule
	local fs = json.alert.flightStatus

	if fs.flightNumber ~= flight[FLIGHT_IDX.FLIGHT] then
		log.error("%s: broken callback: got flightNumber `%s', but expected: `%u'",
			  func, fs.flightNumber, flight[FLIGHT_IDX.FLIGHT])

		return { status = 400 }
	end

	if flight[FLIGHT_IDX.STATUS] == RESERVATION_STATUS.CANCELLED then
		log.warn("%s: got notify for cancelled flight, skip it", func)
		return { status = 200 }
	end

	log.info("%s: got `%s' notify for `%u' flight", func, t, flight[FLIGHT_IDX.FLIGHT])

	if t == 'CANCELLED' then
		return flyd_process_update_cancelled(flight)
	elseif t == 'DIVERTED' then
		return flyd_process_update_diverted(flight, rule, fs)
	elseif t == 'ARRIVAL_GATE' then
		return flyd_process_update_arrival_gate(flight, fs)
	elseif t == 'DEPARTURE_GATE' then
		return flyd_process_update_departure_gate(flight, fs)
	end

	assert(t == 'DEPARTURE_DELAY')

	return flyd_process_update_delay(flight, rule, fs)
end

local function flyd_new_notify_cb(req)
	local func = 'flyd_new_notify_cb'

	local key = req:stash('key')
	assert(key ~= nil)

	if req.method ~= 'POST' then
		log.error("%s: got invalid request (method: `%s', key: `%s')", func, req.method, key)
		return { status = 405 } -- method not allowed
	end

	local ok, json = pcall(req.json, req)
	if not ok then
		log.error("%s: can't decode json: %s", func, json)
		return { status = 400 }
	end

	log.debug("%s: got notify: %s", func, tostring(req))

	local record = callbacks:get{ key }
	if not record then
		log.error("%s: callback with key `%s' not found", func, key)
		return { status = 403 } -- forbidden
	end

	local flight = flights:get{ record[2] }
	assert(flight ~= nil)

	return flyd_process_update(flight, json)
end

local function flyd_get(req, req_str, locale)
	local func = 'flyd_get'

	assert(#req == 6, 'this function take 6 args')

	local reservation_id = table.remove(req, 1)
	local ok, correspond_req = pcall(query.get, query, req)
	if not ok then
		log.error("%s: query `%s' failed: %s", func, req_str, correspond_req)
		return nil
	elseif not correspond_req then
		log.error("%s: query `%s' not found", func, req_str)
		return nil
	elseif correspond_req[QUERY_IDX.STATUS] == FLYD_STATUS.ACTIVE or
	       correspond_req[QUERY_IDX.STATUS] == FLYD_STATUS.RETRY then
		log.error("%s: query `%s' is not complete yet", func, req_str)
		return nil
	elseif correspond_req[QUERY_IDX.STATUS] == FLYD_STATUS.ERROR then
		log.error("%s: provider hasn't info for `%s'", func, req_str)
		return nil
	end

	local carrier, flight, day, month, year = unpack(req)
	if correspond_req[QUERY_IDX.STATUS] == FLYD_STATUS.REGISTER_CB or
	   correspond_req[QUERY_IDX.STATUS] == FLYD_STATUS.RETRY_CB then
		log.warn("%s: callbacks not set yet for `%s' (old data is possible)",
			 func, req_str)
	end

	assert(correspond_req[QUERY_IDX.ID] ~= nil, 'id should be not nil here')
	local record = flights:get{ correspond_req[QUERY_IDX.ID] }
	assert(record ~= nil)

	local departure_city, departure_airport_name
	if record[FLIGHT_IDX.DEP_CODE] then
		local idx = record[FLIGHT_IDX.DEP_CODE]
		local dict = dictionary.iata2airport_info[idx]
		if dict then
			departure_city = dict.city[locale]
			departure_airport_name = dict.name
		end

		if not departure_city then
			log.error("%s: can't find city for `%s' code", func, idx)
		end
	end

	local arrival_city, arrival_airport_name
	if record[FLIGHT_IDX.ARR_CODE] then
		local idx = record[FLIGHT_IDX.ARR_CODE]
		local dict = dictionary.iata2airport_info[idx]
		if dict then
			arrival_city = dict.city[locale]
			arrival_airport_name = dict.name
		end

		if not arrival_city then
			log.error("%s: can't find city for `%s' code", func, idx)
		end
	end

	local provider_name
	if record[FLIGHT_IDX.CARRIER] then
		local idx = record[FLIGHT_IDX.CARRIER]
		provider_name = dictionary.iata2carrier_info[idx]

		if not provider_name then
			log.error("%s: can't find provider name for `%s' code", func, idx)
		end
	end

	assert(record[FLIGHT_IDX.STATUS] == RESERVATION_STATUS.CONFIRMED or
	       record[FLIGHT_IDX.STATUS] == RESERVATION_STATUS.CANCELLED)

	return {
		["@type"] = "FlightReservation",
		["@context"] = "http://schema.org",
		["reservationId"] = reservation_id,
		["reservationStatus"] = RESERVATION_STATUS_STR[record[FLIGHT_IDX.STATUS]],

		["reservationFor"] = {
			["@type"] = "Flight",
			["flightNumber"] = record[FLIGHT_IDX.FLIGHT],

			["provider"] = {
				["@type"] = "Airline",
				["name"] = provider_name,
				["iataCode"] = record[FLIGHT_IDX.CARRIER],
			},

			["departureAirport"] = {
				["@type"] = "Airport",
				["name"] = departure_airport_name,
				["iataCode"] = record[FLIGHT_IDX.DEP_CODE],
			},
			["departureCity"] = {
				["@type"] = "City",
				["name"] = departure_city,
			},
			["departureTime"] = record[FLIGHT_IDX.DEP_DATE],
			["departureGate"] = record[FLIGHT_IDX.DEP_GATE],
			["departureTerminal"] = record[FLIGHT_IDX.DEP_TERM],

			["arrivalAirport"] = {
				["@type"] = "Airport",
				["name"] = arrival_airport_name,
				["iataCode"] = record[FLIGHT_IDX.ARR_CODE],
			},
			["arrivalCity"] = {
				["@type"] = "City",
				["name"] = arrival_city,
			},
			["arrivalTime"] = record[FLIGHT_IDX.ARR_DATE],
			["arrivalGate"] = record[FLIGHT_IDX.ARR_GATE],
			["arrivalTerminal"] = record[FLIGHT_IDX.ARR_TERM],
		}
	}
end

local function tr(str, set1, set2)
	assert(set1:len() == set2:len(),
	       "`set1' and `set2' should have the same size")

	for i = 1, #set1 do
		local a = set1:sub(i,i)
		local b = set2:sub(i,i)

		str = str:gsub(a, b)
	end

	return str
end

local function gamma_generate_url(url, ip)
	url = tr(digest.base64_encode(url), '+/=', '-_~')
	url = url:gsub('\n', '')

	local time = os.time() + 100000
	local secure = digest.md5(config.prepare_secure(url, time))

	secure = tr(digest.base64_encode(secure), '+/', '-_')
	secure = secure:gsub('[= `]', '')

	local res = string.format('http://%s?h=%s&e=%u&is_https=1&url171=%s',
				  ip, secure, time, url)
	log.debug("generated gamma url: `%s'", res)

	return res
end

local function flyd_proxy_single_request(base_url, addr)
	local func = 'flyd_proxy_single_request'
	local url

	if not config.use_gamma_url then
		url = string.format("http://%s/%s", addr, base_url)
	else
		base_url = string.format("%s&appKey=%s&appId=%s", base_url, config.app_key, config.app_id)
		url = gamma_generate_url(base_url, addr)
	end

	log.warn("%s: make new request: `%s' (%s)", func, url, base_url)

	local resp = client.get(url)
	if resp.status == 200 then
		return resp
	end

	-- Normally this shouldn't happend
	log.error("%s: ALERT!!!: http response for `%s': got status `%d' instead of `200', body: `%s'",
		  func, url, resp.status, resp.body)

	return nil
end

local function flyd_http_request(base_url, host)
	if host then
		local resp = flyd_proxy_single_request(base_url, host)
		if resp then
			return resp, host
		end
	end

	for _, addr in ipairs(config.proxy_servers) do
		if addr ~= host then
			local resp = flyd_proxy_single_request(base_url, addr)
			if resp then
				return resp, addr
			end
		end
	end

	return nil
end

local function urlencode(str)
	if str then
		str = string.gsub(str, "\n", "\r\n")
		str = string.gsub(str, "([^%w ])", function (c)
				return string.format("%%%02X", string.byte(c))
			end)
		str = string.gsub(str, " ", "+")
	end

	return str
end

local function flyd_prepare_callback(flight)
	local func = 'flyd_prepare_callback'
	local uid = uuid.str()

	local ok, ret = pcall(callbacks.insert, callbacks, { uid, flight[FLIGHT_IDX.ID] })
	if not ok then
		log.error("%s: can't insert callback info: %s", func, ret)
		return nil
	end

	return uid, urlencode(string.format('http://%s/%s', config.callback_host, uid))
end

local function flyd_register_callbacks(id, flight, addr)
	local func = 'flyd_register_callbacks'

	if not flight then
		flight = flights:get(id)
		assert(flight ~= nil, 'flight should exist here')
	end

	local key = { flight[FLIGHT_IDX.CARRIER], tonumber(flight[FLIGHT_IDX.FLIGHT]),
		      tonumber(day), tonumber(month), tonumber(year) }

	local date = flight[FLIGHT_IDX.DEP_DATE];
	local year, month, day = string.match(date, "^(%d+)-(%d+)-(%d+)")
	if not year then
		-- Don't mark request as error, because we just can't register callback
		query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.DONE}})
		log.error("%s: can't parse date `%s'", func, date)

		return true -- to remove from queue
	end
	assert(year ~= nil and month ~= nil and day ~= nil)

	local uid, cb = flyd_prepare_callback(flight)
	if not uid then
		-- something bad with db (retry later)
		query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.RETRY_CB}})
		return false
	end
	assert(cb ~= nil)

	local events = string.format("can,div,depDelay,depDelayDelta%u,depGate,arrGate", config.dep_delay_delta)
	local base_url = string.format("api.flightstats.com/flex/alerts/rest/v1/json/create/%s/%u/from/%s/departing/%u/%02u/%02u?type=JSON&deliverTo=%s&events=%s&%s",
				       flight[FLIGHT_IDX.CARRIER], flight[FLIGHT_IDX.FLIGHT],
				       flight[FLIGHT_IDX.DEP_CODE], year, month, day, cb,
				       events, 'extendedOptions=useInlinedReferences')

	local resp = flyd_http_request(base_url, addr)
	if not resp then
		query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.DONE}})
		callbacks:delete(uid)

		return false
	end

	local ok, json = pcall(json.decode, resp.body)
	if not ok then
		log.error("%s: can't decode (callbacks): `%s'", func, json)
		query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.DONE}})
		callbacks:delete(uid)

		return true -- to remove from queue
	end

	if json.error then
		log.error("%s: got error `%u': %s", func, json.error.httpStatusCode, json.error.errorMessage)
		query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.DONE}})
		callbacks:delete(uid)

		return true
	end

	log.debug("%s: got json response: `%s'", func, resp.body)

	local upd = query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.DONE}})
	assert(upd, 'update should be successfull')

	log.info("%s: flight {%s,%u,%u,%u,%u}: processed", func, unpack(key))

	return true
end

local function flyd_prepare_flight_record(id, fs)
	local func = 'flyd_prepare_flight_record'

	if type(fs) ~= 'table' then
		log.error("%s: flight `%u': invalid response: `FlightStatus' must be table", func, id)
		return nil
	elseif not fs.carrierFsCode then
		log.error("%s: flight `%u': invalid response: missed `carrierFsCode'", func, id)
		return nil
	elseif not fs.flightNumber then
		log.error("%s: flight `%u': invalid response: missed `flightNumber'", func, id)
		return nil
	elseif not fs.departureAirportFsCode then
		log.error("%s: flight `%u': invalid response: missed `departureAirportFsCode'", func, id)
		return nil
	elseif not fs.arrivalAirportFsCode then
		log.error("%s: flight `%u': invalid response: missed `arrivalAirportFsCode'", func, id)
		return nil
	elseif not fs.departureDate or not fs.departureDate.dateLocal then
		log.error("%s: flight `%u': invalid response: missed `departureDate'", func, id)
		return nil
	elseif not fs.arrivalDate or not fs.arrivalDate.dateLocal then
		log.error("%s: flight `%u': invalid response: missed `arrivalDate'", func, id)
		return nil
	end

	return {
		fs.carrierFsCode,
		fs.flightNumber,

		fs.departureAirportFsCode,
		fs.arrivalAirportFsCode,

		fs.departureDate.dateLocal,
		fs.arrivalDate.dateLocal,

		fs.airportResources and fs.airportResources.departureGate,
		fs.airportResources and fs.airportResources.arrivalGate,

		fs.airportResources and fs.airportResources.departureTerminal,
		fs.airportResources and fs.airportResources.arrivalTerminal,

		RESERVATION_STATUS.CONFIRMED,
	}
end

local function flyd_process_response(req, resp, addr)
	local func = 'flyd_process_response'

	local key = { req[QUERY_IDX.CARRIER], req[QUERY_IDX.FLIGHT],
		      req[QUERY_IDX.DAY], req[QUERY_IDX.MONTH], req[QUERY_IDX.YEAR] }

	local ok, json = pcall(json.decode, resp.body)
	if not ok then
		local upd = query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.ERROR}})
		assert(upd, 'update should be successfull')
		log.error("%s: can't decode: `%s'", func, json)

		return true -- to remove from queue
	end

	if json.error then
		local upd = query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.ERROR}})
		assert(upd, 'update should be successfull')

		log.error("%s: got error `%u': %s", func, json.error.httpStatusCode, json.error.errorMessage)

		return true
	end

	log.debug("%s: got json response: `%s'", func, resp.body)
	if not json.flightStatuses or type(json.flightStatuses) ~= 'table' then
		query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.ERROR}})

		log.error("%s: got invalid json: `flightStatuses' is not table", func)
		return true
	end

	if #json.flightStatuses > 1 then
		log.warn("%s: received more then one flight status, take only the first one", func)
	end

	local rec2ins = flyd_prepare_flight_record(req[QUERY_IDX.FLIGHT], json.flightStatuses[1])
	if not rec2ins then
		local upd = query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.ERROR}})
		assert(upd, 'update should be successfull')

		return true
	end

	local ok, new = pcall(flights.auto_increment, flights, rec2ins)
	if not ok then
		local upd = query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.RETRY}})
		assert(upd, 'update should be successfull')

		log.error("%s: can't insert flight info: %s", func, new)

		return true
	end

	local upd = query:update(key, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.REGISTER_CB}, {'!', -1, new[1]}})
	assert(upd, 'update should be successfull')

	log.debug("%s: flight {%s,%u,%u,%u,%u}: has been stored", func, unpack(key))

	return flyd_register_callbacks(new[1], new, addr)
end

local function flyd_request_do(req)
	if req[QUERY_IDX.STATUS] ~= FLYD_STATUS.ACTIVE then
		assert(req[QUERY_IDX.STATUS] == FLYD_STATUS.RETRY)
		req = query:update(req, {{'=', QUERY_IDX.STATUS, FLYD_STATUS.ACTIVE}})
		assert(req ~= nil, 'update should be successfull')
	end

	local base_url = "api.flightstats.com/flex/flightstatus/rest/v2/json/flight/status"
	base_url = string.format("%s/%s/%u/dep/%u/%02u/%02u?utc=false", base_url,
				 req[QUERY_IDX.CARRIER], req[QUERY_IDX.FLIGHT],
				 req[QUERY_IDX.YEAR], req[QUERY_IDX.MONTH],
				 req[QUERY_IDX.DAY])

	resp, addr = flyd_http_request(base_url)
	if not resp then
		-- Don't retry requests in case http errors
		return true
	end

	return flyd_process_response(req, resp, addr)
end

local function flyd_process_request(req)
	local func = 'flyd_process_request'
	local req_str = table.concat(req, '|')

	-- XXX: remove unneeded `reservation_id'
	-- (do it here just to simplify clients code)
	table.remove(req, 1)

	-- expect arguments: carrier, flight, day, month, year
	if #req ~= 5 then
		log.error("%s: invalid request: expected 5 argumets, but got: `%u'", func, #req)
		return true -- to remove from queue
	end

	local ok, record = pcall(query.get, query, req)
	if not ok then
		log.error("%s: invalid request: select failed: %s", func, record)
		return true
	elseif record ~= nil then
		local status = record[QUERY_IDX.STATUS]

		if status == FLYD_STATUS.DONE or status == FLYD_STATUS.ERROR then
			log.info("%s: request `%s' already processed", func, req_str)
			return true
		elseif status == FLYD_STATUS.ACTIVE or status == FLYD_STATUS.REGISTER_CB then
			log.info("%s: request `%s': is inprogress now", func, req_str)
			return true
		elseif status == FLYD_STATUS.RETRY then
			log.info("%s: request `%s': retry all", func, req_str)
			return flyd_request_do(record)
		end

		assert(status == FLYD_STATUS.RETRY_CB)
		log.info("%s: request `%s': retry register callbacks", func, req_str)

		return flyd_register_callbacks(record[QUERY_IDX.ID])
	end

	table.insert(req, FLYD_STATUS.ACTIVE)
	local ok, descr = pcall(query.insert, query, req)
	if not ok then
		log.error("%s: can't insert query: %s", func, descr)
		return true -- invalid request, remove from queue
	end

	return flyd_request_do(descr)
end

-- reservation_id, carrier, flight, day, month, year
local function flyd_parse_request(request)
	local func = 'flyd_parse_request'

	if (type(request) ~= 'string') then
		log.error("%s: invalid argument: expected string, but got `%s'", func, type(request))
		return false
	end

	local rid, carrier, flight, day, month, year = string.match(request, "([^|]+)|([^|]+)|(%d+)|(%d+)|(%d+)|(%d+)")
	if not year then
		log.error("%s: can't parse request: `%s'", func, request)
		return false
	end

	-- next `tonumber' functions should be ok, because of `string.match'
	flight, day, month, year = tonumber(flight), tonumber(day), tonumber(month), tonumber(year)

	return true, {rid, carrier, flight, day, month, year}
end

---------------------------------------
--             Configuration
---------------------------------------
config = assert(loadfile(path2config))()
box.cfg(config.box)

if config.console then
	console.listen(config.console)
end

if not config.dep_delay_delta then
	config.dep_delay_delta = 5
	log.info("config.dep_delay_delta missed, set to default: %u",
		 config.dep_delay_delta)
end

if not config.retry_timeout then
	config.retry_timeout = 60
	log.info("config.retry_timeout missed, set to default: %u",
		 config.retry_timeout)
end

if not config.path_to_iata_codes then
	log.error("config: missed `path_to_iata_codes' parameter")
	os.exit(1)
end
dictionary = assert(loadfile(config.path_to_iata_codes))()

---------------------------------------
--             Initialization
---------------------------------------

-- Assume, that user hasn't `execute' permission by default
if not box.schema.role.exists('flyd_client_role') then
	box.schema.role.create('flyd_client_role')
	box.schema.role.grant('flyd_client_role', 'read,write,execute', 'universe')
	box.schema.user.grant('guest', 'execute', 'role', 'flyd_client_role')
end

-- Initialize spaces
query = box.space.query
if not query then
	query = box.schema.space.create('query')
	query:create_index('primary', {
		-- carrier iata code, flight num, day, month, year
		parts = {1, 'STR', 2, 'NUM', 3, 'NUM', 4, 'NUM', 5, 'NUM' }
	})
end

flights = box.space.flights
if not flights then
	flights = box.schema.space.create('flights')
	-- `TREE' is used instead of `HASH' just for autoincrement
	flights:create_index('primary', { parts = {1, 'NUM'} })
end

callbacks = box.space.callbacks
if not callbacks then
	callbacks = box.schema.space.create('callbacks')
	callbacks:create_index('primary', { type = 'HASH', parts = {1, 'STR'} })
end

-- Initialize http server
httpd = require('http.server').new(config.http_server.host, config.http_server.port, {
	charset = 'en_US.UTF-8',
	header_timeout = 10,
})

httpd:route({ name = 'root', path = '/:key' }, flyd_new_notify_cb)
httpd:start()

-- Initialize queue
if not queue.tube.requests then
	queue.create_tube('requests', 'fifottl')
end

fiber.create(function ()
	while true do
		local task = queue.tube.requests:take()
		assert(task ~= nil, "`task' shouldn't be `nil' here")

		local id, data = task[1], task[3]

		local ok, ret = pcall(flyd_process_request, data)
		if not ok then
			queue.tube.requests:delete(id)
			log.error("ALERT: task `%d' can't be completed: `%s'", id, ret)
		elseif ret then
			queue.tube.requests:ack(id)
			log.debug("Task `%d' completed", id)
		else
			queue.tube.requests:release(id, { delay = config.retry_timeout })
			log.warn("Task `%d' failed, delay it", id)
		end
	end
end)


---------------------------------------
--             Public API
---------------------------------------

-- Arguments:
--	`locale' - which locale use for response (ru, en) - affect on city name
--	`list' is a table of strings in the following format:
--		`reservation_id|iata_code|flight_number|day|month|year' (`|' is a delimiter)

-- Return value:
--	table of pairs: { key, value(string or false) } for each key from request
--		or empty table in case bad request
local flyd_get_flight_info_json_req_id = 0
function flyd_get_flight_info_json(locale, ...)
	local func = 'flyd_get_flight_info_json'
	list = {...}

	if #list == 0 then
		log.error('%s: invalid argument count (at least two required)', func, type(list))
		return {}
	end

	if locale ~= LOCALE.RU and locale ~= LOCALE.EN then
		log.error("%s: unknown locale: `%s'", func, locale)
		return {}
	end

	local req_id = flyd_get_flight_info_json_req_id
	log.info("start `%s' (%d)", func, req_id)
	flyd_get_flight_info_json_req_id = flyd_get_flight_info_json_req_id + 1

	local resp = {}
	for i = 1, #list do
		local result = false

		local ok, tuple = flyd_parse_request(list[i])
		if ok then
			result = json.encode(flyd_get(tuple, list[i], locale))
		end

		table.insert(resp, { list[i], result })
	end

	log.info("end `%s' (%d)", func, req_id)

	return resp
end

-- Arguments:
--	string in following format: `req1 req2 ... reqN'
--	where `reqI' is: `reservation_id|iata_code|flight_number|day|month|year'
--		(`|' is a delimiter)

-- Return value:
--	empty table in case bad request or
--	table of booleans (`true' - valid request, `false' - otherwise)
local flyd_new_flight_req_id = 0
function flyd_new_flight(request)
	local func = 'flyd_new_flight'

	if type(request) ~= 'string' then
		log.error('%s: invalid argument: string expected, got: %s', func, type(list))
		return {}
	end

	local req_id = flyd_new_flight_req_id
	log.info("start `%s' (%d)", func, req_id)
	flyd_new_flight_req_id = flyd_new_flight_req_id + 1

	local stat = queue.statistics('requests')
	if stat ~= nil then
		local tasks_stat = stat.tasks
		log.info("requests queue statistics: ready: `%d', delayed: `%d', total: `%d', done: `%d'",
			 tasks_stat.ready, tasks_stat.delayed, tasks_stat.total, tasks_stat.done)
	end

	local resp = {}
	for req in string.gmatch(request, '%S+') do
		local ok, tuple = flyd_parse_request(req)
		if ok then
			local task = queue.tube.requests:put(tuple)
			log.debug("%s: append task: `%d'", func, task[1])
		end

		table.insert(resp, ok)
	end

	log.info("end `%s' (%d)", func, req_id)

	return resp
end
