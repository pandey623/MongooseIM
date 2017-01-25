%%%-------------------------------------------------------------------
%%% @author Rafal Slota
%%% @copyright (C) 2017 Erlang Solutions Ltd.
%%% This software is released under the Apache License, Version 2.0
%%% cited in 'LICENSE.txt'.
%%% @end
%%%-------------------------------------------------------------------
%%% @doc
%%% @todo: write me!
%%% @end
%%%-------------------------------------------------------------------
-module(mod_push).
-author("Rafal Slota").
-behavior(gen_mod).
-xep([{xep, 357}, {version, "0.2.1"}]).

-include_lib("ejabberd/include/ejabberd.hrl").
-include_lib("ejabberd/include/jlib.hrl").

%% gen_mod handlers
-export([start/2, stop/1]).

%% Hooks and IQ handlers
-export([handle_offline_message/3, iq_handler/3]).

-callback init(Host :: ejabberd:server(), Opts :: list()) -> ok.
-callback enable(User :: ejabberd:jid(), PubSub :: ejabberd:jid(),
                 Node :: binary(), Forms :: any()) -> ok.
-callback disable(User :: ejabberd:jid(), PubSub :: ejabberd:jid(), Node :: binary()) -> ok.
-callback get_publish_services(User :: ejabberd:jid()) ->
    [{PubSub :: ejabberd:jid(), Node :: binary(), Form :: any()}].

-define(PUSH_FORM_TYPE, <<"urn:xmpp:push:summary">>).


-spec start(Host :: ejabberd:server(), Opts :: list()) -> any().
start(Host, Opts) ->
    ?INFO_MSG("mod_push starting on host ~p", [Host]),

    gen_mod:start_backend_module(?MODULE, Opts, []),
    mod_push_backend:init(Host, Opts),

    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    mod_disco:register_feature(Host, ?NS_PUSH),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_PUSH, ?MODULE,
                                  iq_handler, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_PUSH, ?MODULE,
                                  iq_handler, IQDisc),

    ejabberd_hooks:add(offline_groupchat_message_hook, Host, ?MODULE, handle_offline_message, 1),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, handle_offline_message, 1),

    ok.

stop(Host) ->

    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, handle_offline_message, 1),
    ejabberd_hooks:delete(offline_groupchat_message_hook, Host, ?MODULE, handle_offline_message, 1),

    ok.


-spec handle_offline_message(From :: ejabberd:jid(),
                             To :: ejabberd:jid(),
                             Packet :: jlib:xmlel()) -> ok.
handle_offline_message(From, To, Packet) ->
    ?INFO_MSG("handle_offline_message ~p", [{From, To, Packet}]),

    BareRecipient = jid:to_bare(To),
    Services = mod_push_backend:get_publish_services(BareRecipient),
    lists:foreach(
        fun(PubsubJID, Node, Form) ->
            Stanza = push_notification_stanza(From, BareRecipient, Packet, PubsubJID, Node, Form),
            ejabberd_router:route(To, PubsubJID, Stanza)
        end, Services),

    ok.

-spec iq_handler(From :: ejabberd:jid(), To :: ejabberd:jid(), IQ :: ejabberd:iq()) ->
    ejabberd:iq() | ignore.
iq_handler(_From, _To, IQ = #iq{type = get, sub_el = SubEl}) ->
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
iq_handler(From, _To, IQ = #iq{type = set, sub_el = Request}) ->
    case parse_request(Request) of
        {enable, BarePubsubJID, Node, FormFields} ->
            ok = mod_push_backend:enable(jid:to_bare(From), BarePubsubJID, Node, FormFields),
            IQ#iq{type = result, sub_el = []};
        {disable, BarePubsubJID, Node} ->
            ok = mod_push_backend:disable(jid:to_bare(From), BarePubsubJID, Node),
            IQ#iq{type = result, sub_el = []};
        bad_request ->
            IQ#iq{type = error, sub_el = [Request, ?ERR_BAD_REQUEST]}
    end.


-spec parse_request(Request :: exml:element()) ->
    bad_request.
parse_request(#xmlel{name = <<"enable">>} = Request) ->
    JID = jid:from_binary(exml_query:attr(Request, <<"jid">>, <<>>)),
    Node = exml_query:attr(Request, <<"node">>, <<>>), %% Treat unset node as empty - both forbidden
    Form = exml_query:subelement(Request, <<"x">>),

    case {JID, Node, parse_form(Form)} of
        {_, _, invalid_form}            -> bad_request;
        {_, <<>>, _}                    -> bad_request;
        {error, _, _}                   -> bad_request;
        {#jid{luser = <<>>}, _, _}      -> bad_request;
        {#jid{lserver = <<>>}, _, _}    -> bad_request;
        {JID, Node, FormFields} ->
            {enable, jid:to_bare(JID), Node, FormFields}
    end;
parse_request(#xmlel{name = <<"disable">>} = Request) ->
    JID = jid:from_binary(exml_query:attr(Request, <<"jid">>, <<>>)),
    Node = exml_query:attr(Request, <<"node">>, undefined),

    case {JID, Node} of
        {error, _}                  -> bad_request;
        {_, <<>>}                   -> bad_request; %% Node may not be set, but shouldn't be empty
        {#jid{luser = <<>>}, _}     -> bad_request;
        {#jid{lserver = <<>>}, _}   -> bad_request;
        {JID, Node} ->
            {disable, jid:to_bare(JID), Node}
    end;
parse_request(_) ->
    bad_request.

parse_form(undefined) ->
    [];
parse_form(Form) ->
    IsForm = ?NS_XDATA == exml_query:attr(Form, <<"xmlns">>),
    IsSubmit = <<"submit">> == exml_query:attr(Form, <<"type">>),

    FieldsXML = exml_query:subelements(Form, <<"field">>),
    Fields = [{exml_query:attr(Field, <<"var">>), exml_query:cdata(Field)} || Field <- FieldsXML],
    {[{_, FormType}], CustomFields} = lists:partition(
        fun({Name, _}) ->
            Name == <<"FORM_TYPE">>
        end, Fields),
    IsFormTypeCorrect = ?NS_PUBSUB_PUB_OPTIONS == FormType,

    case IsForm andalso IsSubmit andalso IsFormTypeCorrect of
        true ->
            CustomFields;
        false ->
            invalid_form
    end.


push_notification_stanza(From, To, Packet, PubsubJID, Node, FormFields) ->
    ContentFields = [
        {<<"FORM_TYPE">>, ?PUSH_FORM_TYPE},
        {<<"message-count">>, <<"1">>},
        {<<"last-message-sender">>, jid:to_binary(From)},
        {<<"last-message-body">>, exml_query:cdata(exml_query:subelement(Packet, <<"body">>))}
    ],

    AlmostStanza = jlib:iq_to_xml(#iq{type = set, sub_el = [
        #xmlel{name = <<"pubsub">>, attrs = [{<<"xmlns">>, ?NS_PUBSUB}], children = [
            #xmlel{name = <<"publish">>, attrs = [{<<"node">>, Node}], children = [
                #xmlel{name = <<"item">>, children = [
                    #xmlel{name = <<"notification">>,
                           attrs = [{<<"xmlns">>, ?NS_PUSH}], children = [make_form(ContentFields)]}
                ]}
            ]},
            #xmlel{name = <<"publish-options">>, children = [
                make_form([{<<"FORM_TYPE">>, ?NS_PUBSUB_PUB_OPTIONS}] ++ FormFields)
            ]}
        ]}
    ]}),

    jlib:replace_from_to(To, PubsubJID, AlmostStanza).


make_form(Fields) ->
    #xmlel{name = <<"x">>, attrs = [{<<"xmlns">>, ?NS_XDATA}, {<<"type">>, <<"submit">>}],
           children = [make_form_field(Name, Value) || {Name, Value} <- Fields]}.

make_form_field(Name, Value) ->
    #xmlel{name = <<"field">>,
           attrs = [{<<"var">>, Name}],
           children = [#xmlcdata{content = Value}]}.