module Restful.Endpoint
    exposing
        ( AccessToken
        , BackendUrl
        , EndPoint
        , EntityId
        , decodeEntityId
        , decodeId
        , decodeSingleEntity
        , encodeEntityId
        , fromEntityId
        , get
        , get404
        , patch
        , patch_
        , post
        , put
        , put_
        , select
        , toEntityId
        , (</>)
        )

{-| These functions facilitate CRUD operations upon entities exposed through a
Restful API. It is oriented towards a Drupal backend, but could be used (or
modified to use) with other backends that produce similar JSON.


## Types

@docs EndPoint, EntityId, AccessToken, BackendUrl


## CRUD Operations

@docs get, get404, select, patch, patch_, post, put, put_


## JSON

@docs decodeEntityId, decodeId, decodeSingleEntity, encodeEntityId, fromEntityId, toEntityId


## Helpers

@docs (</>)

-}

import Gizra.Json exposing (decodeInt)
import Http exposing (Error(..), expectJson)
import HttpBuilder exposing (..)
import Json.Decode exposing (Decoder, field, index, list, map, map2)
import Json.Encode exposing (Value)
import Maybe.Extra


{-| The base URL for a backend.
-}
type alias BackendUrl =
    String


{-| An access token.
-}
type alias AccessToken =
    String


{-| This is a start at a nicer idiom for dealing with Restful JSON endpoints.
The basic idea is to include in this type all those things about an endpoint
which don't change. For instance, we know the path of the endpoint, what kind
of JSON it emits, etc. -- that never varies.

In the type parameters:

    - the `key` is the type of the wrapper around `Int` for the node id.
    - the `value` is the type of the value
    - the `params` is a type for the query params that this endpoint takes
      If your endpoint doesn't take params, just use `()` (or, a phantom
      type variable, if you like).
    - the `error` is the error type. If you don't want to do something
      special with errors, then it can just be `Http.Error`

-}
type alias EndPoint error params key value =
    -- The relative path to the endpoint ... that is, the part after the backendUrl
    { path : String

    -- The tag which wraps the integer node ID. (This assumes an integer node
    -- ID ... we could make it more general someday if needed).
    , tag : Int -> key

    -- Does the reverse of `tag` -- given a key, produces an `Int`
    --
    -- TODO: If we insisted on using an `EntityId ...` as the key, we could
    -- get rid of tag and untag (since they would always be `toEntityId` and
    -- `fromEntityId`). This is probably desirable, but making the types work
    -- will take a bit of effort.
    , untag : key -> Int

    -- A decoder for the values
    , decoder : Decoder value

    -- An encoder for the value. The ID will be added automatically ... you
    -- just need to supply the key-value pairs to encode the value itself.
    , encoder : value -> Value

    -- You may want to use your own error type. If so, provided something
    -- that maps from the kind of `Http.Error` this endpoint produces to
    -- your local error type. If you just want to use `Http.Error` dirdctly
    -- as the error type, then you can supply `identity`.
    , error : Http.Error -> error

    -- This takes your typed `params` and turns them into something that
    -- we can feed into `withQueryParams`. So, we get compile-time type-safety
    -- for our params ... isn't that nice? And you could use `Maybe` judiciously
    -- in your `params` type if you want some or all params to be optional.
    --
    -- If you never take params, then you can supply `always []`
    , params : params -> List ( String, String )
    }


{-| Appends left-to-right, joining with a "/" if needed.
-}
(</>) : String -> String -> String
(</>) left right =
    if String.endsWith "/" left || String.startsWith "/" right then
        left ++ right
    else
        left ++ "/" ++ right


{-| Select entities from an endpoint.

What we hand you is a `Result` with a list of entities, since that is the most
"natural" thing to hand back. You can convert it to a `RemoteData` easily with
a `RemoteData.fromResult` if you like.

The `error` type parameter allows the endpoint to have locally-typed errors. You
can just use `Http.Error`, though, if you want to.

-}
select : BackendUrl -> Maybe AccessToken -> EndPoint error params key value -> params -> (Result error (List ( key, value )) -> msg) -> Cmd msg
select backendUrl accessToken endpoint params tagger =
    let
        queryParams =
            accessToken
                |> Maybe.Extra.toList
                |> List.map (\token -> ( "access_token", token ))
                |> List.append (endpoint.params params)
    in
        HttpBuilder.get (backendUrl </> endpoint.path)
            |> withQueryParams queryParams
            |> withExpect (expectJson (decodeData (list (map2 (,) (decodeId endpoint.tag) endpoint.decoder))))
            |> send (Result.mapError endpoint.error >> tagger)


{-| Gets a entity from the backend via its ID.

If we get a 404 error, we'll give you an `Ok Nothing`, rather than an error,
since the request essentially succeeded ... there merely was no entity with
that ID.

-}
get : BackendUrl -> Maybe AccessToken -> EndPoint error params key value -> key -> (Result error (Maybe ( key, value )) -> msg) -> Cmd msg
get backendUrl accessToken endpoint key tagger =
    let
        queryParams =
            accessToken
                |> Maybe.Extra.toList
                |> List.map (\token -> ( "access_token", token ))
    in
        HttpBuilder.get (backendUrl </> endpoint.path </> toString (endpoint.untag key))
            |> withQueryParams queryParams
            |> withExpect (expectJson (decodeSingleEntity (map2 (,) (decodeId endpoint.tag) endpoint.decoder)))
            |> send
                (\result ->
                    let
                        recover =
                            case result of
                                Err (BadStatus response) ->
                                    if response.status.code == 404 then
                                        Ok Nothing
                                    else
                                        Result.map Just result

                                _ ->
                                    Result.map Just result
                    in
                        recover
                            |> Result.mapError endpoint.error
                            |> tagger
                )


{-| Let `get`, but treats a 404 response as an error in the `Result`, rather than a `Nothing` response.
-}
get404 : BackendUrl -> Maybe AccessToken -> EndPoint error params key value -> key -> (Result error ( key, value ) -> msg) -> Cmd msg
get404 backendUrl accessToken endpoint key tagger =
    let
        queryParams =
            accessToken
                |> Maybe.Extra.toList
                |> List.map (\token -> ( "access_token", token ))
    in
        HttpBuilder.get (backendUrl </> endpoint.path </> toString (endpoint.untag key))
            |> withQueryParams queryParams
            |> withExpect (expectJson (decodeSingleEntity (map2 (,) (decodeId endpoint.tag) endpoint.decoder)))
            |> send (Result.mapError endpoint.error >> tagger)


{-| Sends a `POST` request to create the specified value.
-}
post : BackendUrl -> Maybe AccessToken -> EndPoint error params key value -> value -> (Result error ( key, value ) -> msg) -> Cmd msg
post backendUrl accessToken endpoint value tagger =
    let
        queryParams =
            accessToken
                |> Maybe.Extra.toList
                |> List.map (\token -> ( "access_token", token ))
    in
        HttpBuilder.post (backendUrl </> endpoint.path)
            |> withQueryParams queryParams
            |> withExpect (expectJson (decodeSingleEntity (map2 (,) (decodeId endpoint.tag) endpoint.decoder)))
            |> withJsonBody (endpoint.encoder value)
            |> send (Result.mapError endpoint.error >> tagger)


{-| Sends a `PUT` request to create the specified value.

Assumes that the backend will respond with the full value. If that's not true, you
can use `put_` instead.

-}
put : BackendUrl -> Maybe AccessToken -> EndPoint error params key value -> key -> value -> (Result error value -> msg) -> Cmd msg
put backendUrl accessToken endpoint key value tagger =
    let
        queryParams =
            accessToken
                |> Maybe.Extra.toList
                |> List.map (\token -> ( "access_token", token ))
    in
        HttpBuilder.put (backendUrl </> endpoint.path </> toString (endpoint.untag key))
            |> withQueryParams queryParams
            |> withExpect (expectJson (decodeSingleEntity endpoint.decoder))
            |> withJsonBody (endpoint.encoder value)
            |> send (Result.mapError endpoint.error >> tagger)


{-| Like `put`, but ignores any value sent by the backend back ... just interprets errors.
-}
put_ : BackendUrl -> Maybe AccessToken -> EndPoint error params key value -> key -> value -> (Result error () -> msg) -> Cmd msg
put_ backendUrl accessToken endpoint key value tagger =
    let
        queryParams =
            accessToken
                |> Maybe.Extra.toList
                |> List.map (\token -> ( "access_token", token ))
    in
        HttpBuilder.put (backendUrl </> endpoint.path </> toString (endpoint.untag key))
            |> withQueryParams queryParams
            |> withJsonBody (endpoint.encoder value)
            |> send (Result.mapError endpoint.error >> tagger)


{-| Sends a `PATCH` request for the specified key and value.

Now, the point of a `PATCH` request is that you're not sending the **full** value,
but some subset. So, you supply your own JSON value, rather than using the one that
the endpoint would create use for PUT or POST. (We could have a separate config for
each kind of PATCH, which would contribute to type-safety, but is possibly overkill).

This function assumes that the backend will send the full value back. If it won't, then
you can use `patch_` instead.

-}
patch : BackendUrl -> Maybe AccessToken -> EndPoint error params key value -> key -> Value -> (Result error value -> msg) -> Cmd msg
patch backendUrl accessToken endpoint key value tagger =
    let
        queryParams =
            accessToken
                |> Maybe.Extra.toList
                |> List.map (\token -> ( "access_token", token ))
    in
        HttpBuilder.patch (backendUrl </> endpoint.path </> toString (endpoint.untag key))
            |> withQueryParams queryParams
            |> withExpect (expectJson (decodeSingleEntity endpoint.decoder))
            |> withJsonBody value
            |> send (Result.mapError endpoint.error >> tagger)


{-| Like `patch`, but doesn't try to decode the response ... just reports errors.
-}
patch_ : BackendUrl -> Maybe AccessToken -> EndPoint error params key value -> key -> Value -> (Result error () -> msg) -> Cmd msg
patch_ backendUrl accessToken endpoint key value tagger =
    let
        queryParams =
            accessToken
                |> Maybe.Extra.toList
                |> List.map (\token -> ( "access_token", token ))
    in
        HttpBuilder.patch (backendUrl </> endpoint.path </> toString (endpoint.untag key))
            |> withQueryParams queryParams
            |> withJsonBody value
            |> send (Result.mapError endpoint.error >> tagger)



{- If we have an `Existing` storage key, then update the backend via `patch`.

   If we have a `New` storage key, insert it in the backend via `post`.

   TODO: At the moment, we "patch" everything we would normally "post".l

-}
{-
   upsert : BackendUrl -> Maybe AccessToken -> EndPoint error params key value -> Entity key value -> (Result error (Entity key value) -> msg) -> Cmd msg
   upsert backendUrl accessToken endpoint (key, value) tagger =
       let
           queryParams =
               accessToken
                   |> Maybe.Extra.toList
                   |> List.map (\token -> ( "access_token", token ))

           encodedValue =
               endpoint.encoder value
       in
           case key of
               Existing id ->
                   HttpBuilder.patch (backendUrl </> endpoint.path </> toString (endpoint.untag id)
                       |> withQueryParams queryParams
                       |> withJsonBody
                       |> withExpect (expectJson (decodeSingleEntity (decodeStorageTuple (decodeId endpoint.tag) endpoint.decoder)))
                       |> send (Result.mapError endpoint.error >> tagger)

               New ->
                   HttpBuilder.post (backendUrl </> endpoint.path)
                       |> withQueryParams queryParams
                       |> withJsonBody (config.encodeStorage ( key, value ))
                       |> withExpect (Http.expectJson (decodeSingleEntity config.decodeStorage))
                       |> send config.handler
-}


{-| Convenience for the pattern where you have a field called "id",
and you want to wrap the result in a type (e.g. PersonId Int). You can
just use `decodeId PersonId`.
-}
decodeId : (Int -> a) -> Decoder a
decodeId wrapper =
    map wrapper (field "id" decodeInt)


decodeData : Decoder a -> Decoder a
decodeData =
    field "data"


{-| Given a decoder for an entity, applies it to a JSON response that consists
of a `data` field with a array of length 1, containing the entity. (This is
what Drupal sends when you do a PUT, POST, or PATCH.)

For instance, if you POST an entity, Drupal will send back the JSON for that entity,
as the single element of an array, then wrapped in a `data` field, e.g.:

    { data :
        [
            {
                id: 27,
                label: "The label",
                ...
            }
        ]
    }

To decode this, write a decoder for the "inner" part (the actual entity), and then
supply that as a parameter to `decodeSingleEntity`.

-}
decodeSingleEntity : Decoder a -> Decoder a
decodeSingleEntity =
    decodeData << index 0


{-| This is a wrapper for an `Int` id. It takes a "phantom" type variable
in order to gain type-safety about what kind of entity it is an ID for.
So, to specify that you have an id for a clinic, you would say:

    clinidId : EntityId ClinicId

-}
type EntityId a
    = EntityId Int


{-| This is how you create a EntityId, if you have an `Int`. You can create
any kind of `EntityId` this way ... so you would normally only do this in
situations that are fundamentally untyped, such as when you are decoding
JSON data. Except in those kind of "boundary" situations, you should be
working with the typed EntityIds.
-}
toEntityId : Int -> EntityId a
toEntityId =
    EntityId


{-| This is how you get an `Int` back from a `EntityId`. You should only use
this in boundary situations, where you need to send the id out in an untyped
way. Normally, you should just pass around the `EntityId` itself, to retain
type-safety.
-}
fromEntityId : EntityId a -> Int
fromEntityId (EntityId a) =
    a


{-| Decodes a EntityId.

This just turns JSON int (or string that is an int) to a EntityId. You need
to supply the `field "id"` yourself, if necessary, since id's could be present
in other fields as well.

This decodes any kind of EntityId you like (since there is fundamentally no type
information in the JSON iself, of course). So, you need to verify that the type
is correct yourself.

-}
decodeEntityId : Decoder (EntityId a)
decodeEntityId =
    Json.Decode.map toEntityId decodeInt


{-| Encodes any kind of `EntityId` as a JSON int.
-}
encodeEntityId : EntityId a -> Value
encodeEntityId =
    Json.Encode.int << fromEntityId
