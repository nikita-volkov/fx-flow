module FxFlow
where

import FxFlow.Prelude
import qualified Fx


-- * Accessor
-------------------------

{-|
Block running a flow until an async exception gets raised or the actor system fails with an error.
-}
spawn :: Spawner env err (Flow () ()) -> Accessor env (Either SomeException err) ()
spawn (Spawner def) = do
  errChan <- Fx.mapErr Left $ Fx.io $ newTQueueIO
  (flow, killers) <- Fx.mapErr Left $ Fx.use $ \ env -> Fx.io $ runStateT (runReaderT def (env, errChan)) []
  err <- Fx.mapErr Left $ Fx.io $ atomically $ readTQueue errChan
  Fx.mapErr Left $ Fx.io $ fold killers
  throwError err


-- * Spawner
-------------------------

{-|
Context for spawning of actors.
-}
newtype Spawner env err a = Spawner (ReaderT (env, TQueue (Either SomeException err)) (StateT [IO ()] IO) a)
  deriving (Functor, Applicative, Monad)
  
{-|
Spawn an actor.
-}
act :: Int -> (i -> Accessor env err o) -> Spawner env err (Flow i o)
act queueSize step = Spawner $ ReaderT $ \ (env, errChan) -> StateT $ \ killers -> do
  queue <- newTBQueueIO (fromIntegral queueSize)
  forkIO $ fix $ \ loop -> do
    entry <- atomically $ readTBQueue queue
    case entry of
      Just (i, cont) -> do
        o <- error "TODO"
        cont o
        loop
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

instance ArrowChoice Flow where
  left = left'

instance Profunctor Flow where
  dimap fn1 fn2 (Flow def) = Flow $ \ i cont -> def (fn1 i) (cont . fn2)

instance Strong Flow where
  first' = (*** id)
  second' = (id ***)

instance Choice Flow where
  left' (Flow def) = Flow $ \ i cont -> case i of
    Left i -> def i (cont . Left)
    Right i -> cont (Right i)
