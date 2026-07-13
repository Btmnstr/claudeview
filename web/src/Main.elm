port module Main exposing (main)

{-| The ClaudeView viewer.

It knows almost nothing: on every SSE ping it re-fetches `/content` (the list of
tabs, already rendered to HTML by the server, plus the directories being watched)
and shows the tab the server marks as focused — the most recently modified one.
Clicking a tab pins it until the next content change.

A slim header shows what the server is watching and whether the live connection
is up, so an empty screen still tells you where to look.
-}

import Browser
import Html exposing (Html, button, div, node, span, text)
import Html.Attributes exposing (class, classList, property)
import Html.Events exposing (onClick)
import Http
import Json.Decode as D
import Json.Encode as E


-- PORTS


port sseMessage : (String -> msg) -> Sub msg


port sseStatus : (Bool -> msg) -> Sub msg


port setTheme : String -> Cmd msg



-- MODEL


type alias Tab =
    { name : String, html : String, mtime : Int }


type alias Model =
    { tabs : List Tab
    , focus : Maybe String
    , watching : List String
    , connected : Bool
    , theme : String
    }


{-| The flag is the theme JS resolved before first paint ("light" or "dark").
-}
init : String -> ( Model, Cmd Msg )
init theme =
    ( { tabs = [], focus = Nothing, watching = [], connected = False, theme = theme }, fetchContent )



-- UPDATE


type alias Content =
    { tabs : List Tab, focus : Maybe String, watching : List String }


type Msg
    = Ping String
    | Status Bool
    | GotContent (Result Http.Error Content)
    | Focus String
    | ToggleTheme


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Ping _ ->
            ( model, fetchContent )

        Status connected ->
            ( { model | connected = connected }, Cmd.none )

        GotContent (Ok c) ->
            ( { model | tabs = c.tabs, focus = c.focus, watching = c.watching }, Cmd.none )

        GotContent (Err _) ->
            ( model, Cmd.none )

        Focus name ->
            ( { model | focus = Just name }, Cmd.none )

        ToggleTheme ->
            let
                next =
                    if model.theme == "dark" then
                        "light"

                    else
                        "dark"
            in
            ( { model | theme = next }, setTheme next )


fetchContent : Cmd Msg
fetchContent =
    Http.get { url = "/content", expect = Http.expectJson GotContent decoder }


decoder : D.Decoder Content
decoder =
    D.map3 Content
        (D.field "tabs" (D.list tabDecoder))
        (D.field "focus" (D.nullable D.string))
        (D.maybe (D.field "watching" (D.list D.string)) |> D.map (Maybe.withDefault []))


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
        [ header model
        , div [ class "tabs" ] (List.map (tab model.focus) model.tabs)
        , contentPane model
        ]


header : Model -> Html Msg
header model =
    div [ class "header" ]
        [ span [ class "brand" ] [ text "ClaudeView" ]
        , span [ class "watching" ] [ text (watchingLabel model.watching) ]
        , span
            [ classList [ ( "status", True ), ( "live", model.connected ) ] ]
            [ text
                (if model.connected then
                    "live"

                 else
                    "offline"
                )
            ]
        , button [ class "theme-toggle", onClick ToggleTheme ]
            [ text
                (if model.theme == "dark" then
                    "☀ light"

                 else
                    "☾ dark"
                )
            ]
        ]


watchingLabel : List String -> String
watchingLabel dirs =
    case dirs of
        [] ->
            "watching: (unknown)"

        _ ->
            "watching: " ++ String.join ", " dirs


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
            div [ class "content empty" ]
                [ text (emptyMessage model.watching) ]


emptyMessage : List String -> String
emptyMessage dirs =
    case dirs of
        [] ->
            "Waiting for content…"

        _ ->
            "No tabs yet. Drop a .md file into " ++ String.join " or " dirs ++ ", or run a plan."



-- MAIN


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch [ sseMessage Ping, sseStatus Status ]


main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
