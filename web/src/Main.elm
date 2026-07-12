port module Main exposing (main)

{-| The ClaudeView viewer.

It knows almost nothing: on every SSE ping it re-fetches `/content` (the full
list of tabs, already rendered to HTML by the server) and shows the tab the
server marks as focused — the most recently modified one. Clicking a tab pins it
until the next content change.
-}

import Browser
import Html exposing (Html, button, div, node, text)
import Html.Attributes exposing (class, classList, property)
import Html.Events exposing (onClick)
import Http
import Json.Decode as D
import Json.Encode as E


-- PORTS


port sseMessage : (String -> msg) -> Sub msg



-- MODEL


type alias Tab =
    { name : String, html : String, mtime : Int }


type alias Model =
    { tabs : List Tab, focus : Maybe String }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { tabs = [], focus = Nothing }, fetchContent )



-- UPDATE


type Msg
    = Ping String
    | GotContent (Result Http.Error Model)
    | Focus String


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Ping _ ->
            ( model, fetchContent )

        GotContent (Ok fresh) ->
            ( fresh, Cmd.none )

        GotContent (Err _) ->
            ( model, Cmd.none )

        Focus name ->
            ( { model | focus = Just name }, Cmd.none )


fetchContent : Cmd Msg
fetchContent =
    Http.get { url = "/content", expect = Http.expectJson GotContent decoder }


decoder : D.Decoder Model
decoder =
    D.map2 Model
        (D.field "tabs" (D.list tabDecoder))
        (D.field "focus" (D.nullable D.string))


tabDecoder : D.Decoder Tab
tabDecoder =
    D.map3 Tab
        (D.field "name" D.string)
        (D.field "html" D.string)
        (D.field "mtime" D.int)



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "app" ]
        [ div [ class "tabs" ] (List.map (tab model.focus) model.tabs)
        , contentPane model
        ]


tab : Maybe String -> Tab -> Html Msg
tab focus t =
    button
        [ classList [ ( "tab", True ), ( "active", focus == Just t.name ) ]
        , onClick (Focus t.name)
        ]
        [ text t.name ]


contentPane : Model -> Html Msg
contentPane model =
    case List.filter (\t -> Just t.name == model.focus) model.tabs of
        t :: _ ->
            -- `<raw-html>` is a custom element (see index.html) that renders the
            -- server-produced HTML string, keeping this Elm code free of markdown.
            node "raw-html" [ class "content", property "content" (E.string t.html) ] []

        [] ->
            div [ class "content empty" ] [ text "Waiting for content…" ]



-- MAIN


subscriptions : Model -> Sub Msg
subscriptions _ =
    sseMessage Ping


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
