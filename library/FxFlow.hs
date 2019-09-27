module FxFlow
(
  -- * Accessor
  spawn,
  -- * Spawner
  Spawner,
  react,
  -- * Flow
  Flow,
  permanently,
)
where

import FxFlow.Prelude
import qualified Fx


-- * Accessor
-------------------------

{-|
Block running a network of actors until one of the following happens:

- Flow produces the first output;
- An @err@ error gets raised by anything involved;
- An async exception gets raised. That's what `SomeException` stands for.

The first parameter is an action,
which gets executed in loop,
each time producing an input for the network of actors,
specified by `Flow`.
-}
spawn :: Accessor env err inp -> Spawner env err (Flow inp out) -> Accessor env (Either SomeException err) out
spawn producer (Spawner def) = do

  errOrRes <- Fx.use $ \ env -> bimap1 Left $ Fx.io $ do
    errChan <- newTQueueIO
    let emitErr = atomically . writeTQueue errChan

    -- Spawn all the flow workers:
    (Flow emitInp, flowKillers) <- runStateT (runReaderT def (env, emitErr)) []

    resVar <- newEmptyTMVarIO

    -- Spawn the producer loop:
    forkIO $ fix $ \ loop -> do

      -- Check that we're not dead yet:
      alive <- atomically $
        (False <$ readTMVar resVar) <|>
        (False <$ peekTQueue errChan) <|>
        (pure True)

      when alive $ do
        errOrInp <- Fx.uio $ runExceptT $ Fx.eio $ Fx.providerAndAccessor (pure env) producer
        case errOrInp of
          Right inp -> do
            emitInp inp $ \ out -> atomically $ putTMVar resVar out
            loop
          Left err -> emitErr (Right err)

    -- Block waiting for error or result:
    errOrRes <- atomically $ Right <$> readTMVar resVar <|> Left <$> peekTQueue errChan

    -- Kill all forked threads:
    fold flowKillers

    return errOrRes

  either throwError return errOrRes


-- * Spawner
-------------------------

{-|
Context for spawning of actors.
-}
newtype Spawner env err a = Spawner (ReaderT (env, Either SomeException err -> IO ()) (StateT [IO ()] IO) a)
  deriving (Functor, Applicative, Monad)

{-|
Spawn a reactor with an input message buffer of size limited to the specified size,
producing a flow, which outputs results.
-}
react :: Int -> (i -> Accessor env err o) -> Spawner env err (Flow i o)
react queueSize step = Spawner $ ReaderT $ \ (env, emitErr) -> StateT $ \ killers -> do
  queue <- newTBQueueIO (fromIntegral queueSize)
  forkIO $ fix $ \ loop -> do
    entry <- atomically $ readTBQueue queue
    case entry of
      Just (i, cont) -> do
        errOrOut <- Fx.uio $ runExceptT $ Fx.eio $ Fx.providerAndAccessor (pure env) $ step i
        case errOrOut of
          Right out -> do
            cont out
            loop
          Left err -> emitErr (Right err)
      Nothing -> return ()
  let
    flow = Flow $ \ i cont -> atomically $ writeTBQueue queue (Just (i, cont))
    newKillers = (atomically (writeTBQueue queue Nothing)) : killers
    in return (flow, newKillers)


-- * Flow
-------------------------

{-|
Actor communication network composition.
Specifies the message flow between them.
-}
newtype Flow i o = Flow (i -> (o -> IO ()) -> IO ())

instance Category Flow where
  id = Flow $ \ inp cont -> cont inp
  (.) (Flow def1) (Flow def2) = Flow $ \ i cont -> def2 i (flip def1 cont)

instance Arrow Flow where
  arr fn = Flow $ \ inp cont -> cont (fn inp)
  (***) (Flow def1) (Flow def2) = Flow $ \ (inp1, inp2) cont -> do
    out1Var <- newTVarIO Nothing
    out2Var <- newTVarIO Nothing
    def1 inp1 $ \ out1 -> join $ atomically $ do
      out2Setting <- readTVar out2Var
      case out2Setting of
        Just out2 -> return $ cont (out1, out2)
        Nothing -> do
          writeTVar out1Var (Just out1)
          return (return ())
    def2 inp2 $ \ out2 -> join $ atomically $ do
      out1Setting <- readTVar out1Var
      case out1Setting of
        Just out1 -> return $ cont (out1, out2)
        Nothing -> do
          writeTVar out2Var (Just out2)
          return (return ())
  first = first'
  second = second'

instance ArrowChoice Flow where
  left = left'

instance ArrowZero Flow where
  zeroArrow = Flow $ \ i cont -> return ()

instance ArrowPlus Flow where
  (<+>) (Flow flowIo1) (Flow flowIo2) = Flow $ \ i cont -> do
    flowIo1 i cont
    flowIo2 i cont

instance ArrowApply Flow where
  app = Flow $ \ (Flow flowIo, i) cont -> flowIo i cont

instance Profunctor Flow where
  dimap fn1 fn2 (Flow def) = Flow $ \ i cont -> def (fn1 i) (cont . fn2)

instance Strong Flow where
  first' (Flow flowIo) = Flow $ \ (inp1, inp2) cont -> flowIo inp1 $ \ out1 -> cont (out1, inp2)

instance Choice Flow where
  left' (Flow def) = Flow $ \ i cont -> case i of
    Left i -> def i (cont . Left)
    Right i -> cont (Right i)

{-|
Turn a flow, which produces unit into a flow,
which only consumes input and never produces output.

This is a tool for creating permanent processes,
which never stop themselves and
can only be stopped due to errors or user interruption (thru async exception).
-}
permanently :: Flow i () -> Flow i Void
permanently (Flow flowIo) = Flow $ \ i _ -> flowIo i (const (return ()))
