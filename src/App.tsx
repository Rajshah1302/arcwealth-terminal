import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import Layout from '@/components/Layout'
import Landing from '@/pages/Landing'
import Dashboard from '@/pages/Dashboard'
import Trading from '@/pages/Trading'
import Lending from '@/pages/Lending'
import SifList from '@/pages/SifList'
import SifDetail from '@/pages/SifDetail'
import Portfolio from '@/pages/Portfolio'
import History from '@/pages/History'
import Profile from '@/pages/Profile'
import Admin from '@/pages/Admin'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Layout />}>
          <Route index element={<Landing />} />
          <Route path="dashboard" element={<Dashboard />} />
          <Route path="trading" element={<Trading />} />
          <Route path="lending" element={<Lending />} />
          <Route path="sif" element={<SifList />} />
          <Route path="sif/:id" element={<SifDetail />} />
          <Route path="portfolio" element={<Portfolio />} />
          <Route path="history" element={<History />} />
          <Route path="profile" element={<Profile />} />
          <Route path="admin" element={<Admin />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
